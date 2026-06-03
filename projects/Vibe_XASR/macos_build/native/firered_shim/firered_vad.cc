// firered_vad.cc — Streaming implementation of the FireRedVAD C API.
// C++ internals, C interface (extern "C" via firered_vad.h).
//
// Parity contract with native/vad_check.cc:
//   * Same Fbank options, same CMVN, same 30-frame ONNX chunking carrying the
//     [8,1,128,19] cache, same StreamVadPostprocessor, same segment math.
//   * Streaming: Fbank is fed incrementally; ONNX runs once per completed
//     30-frame chunk so the cache decomposition is byte-identical to vad_check
//     (chunk boundaries fall on the same absolute frame indices 0,30,60,...).

#include "firered_vad.h"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <deque>
#include <fstream>
#include <memory>
#include <string>
#include <vector>

#include "kaldi-native-fbank/csrc/online-feature.h"
#include "onnxruntime_cxx_api.h"

namespace {

template <typename T>
bool read_bin(const std::string& p, std::vector<T>* out) {
  std::ifstream f(p, std::ios::binary | std::ios::ate);
  if (!f) return false;
  std::streamsize n = f.tellg();
  if (n < 0) return false;
  f.seekg(0);
  out->resize(static_cast<size_t>(n) / sizeof(T));
  f.read(reinterpret_cast<char*>(out->data()), n);
  return static_cast<bool>(f);
}

// ---- StreamVadPostprocessor port (verbatim from vad_check.cc) ----
struct FrameResult {
  int frame_idx;
  bool is_speech_start = false, is_speech_end = false;
  int speech_start_frame = -1, speech_end_frame = -1;
};

struct PostProc {
  int smoothN, pad_start, min_speech, max_speech, min_silence;
  float thr;
  // state
  int frame_cnt = 0;
  std::deque<float> win;
  double win_sum = 0;
  int state = 0;  // 0 SILENCE 1 POSSIBLE_SPEECH 2 SPEECH 3 POSSIBLE_SILENCE
  int speech_cnt = 0, silence_cnt = 0;
  bool hit_max = false;
  int last_start = -1, last_end = -1;

  PostProc(int sN, float t, int ps, int msp, int mxs, int msl)
      : smoothN(std::max(1, sN)),
        pad_start(std::max(std::max(1, sN), ps)),
        min_speech(msp),
        max_speech(mxs),
        min_silence(msl),
        thr(t) {}

  FrameResult process(float raw) {
    frame_cnt++;
    float sm = raw;
    if (smoothN > 1) {
      win.push_back(raw);
      win_sum += raw;
      if ((int)win.size() > smoothN) {
        win_sum -= win.front();
        win.pop_front();
      }
      sm = (float)(win_sum / win.size());
    }
    int is_speech = (sm >= thr) ? 1 : 0;
    FrameResult r;
    r.frame_idx = frame_cnt;

    if (hit_max) {
      r.is_speech_start = true;
      r.speech_start_frame = frame_cnt;
      last_start = frame_cnt;
      hit_max = false;
    }
    if (state == 0) {
      if (is_speech) {
        state = 1;
        speech_cnt++;
      } else {
        silence_cnt++;
        speech_cnt = 0;
      }
    } else if (state == 1) {
      if (is_speech) {
        speech_cnt++;
        if (speech_cnt >= min_speech) {
          state = 2;
          r.is_speech_start = true;
          r.speech_start_frame =
              std::max({1, frame_cnt - speech_cnt + 1 - pad_start, last_end + 1});
          last_start = r.speech_start_frame;
          silence_cnt = 0;
        }
      } else {
        state = 0;
        silence_cnt = 1;
        speech_cnt = 0;
      }
    } else if (state == 2) {
      speech_cnt++;
      if (is_speech) {
        silence_cnt = 0;
        if (speech_cnt >= max_speech) {
          hit_max = true;
          speech_cnt = 0;
          r.is_speech_end = true;
          r.speech_end_frame = frame_cnt;
          r.speech_start_frame = last_start;
          last_start = -1;
          last_end = r.speech_end_frame;
        }
      } else {
        state = 3;
        silence_cnt++;
      }
    } else {  // POSSIBLE_SILENCE
      speech_cnt++;
      if (is_speech) {
        state = 2;
        silence_cnt = 0;
        if (speech_cnt >= max_speech) {
          hit_max = true;
          speech_cnt = 0;
          r.is_speech_end = true;
          r.speech_end_frame = frame_cnt;
          r.speech_start_frame = last_start;
          last_start = -1;
          last_end = r.speech_end_frame;
        }
      } else {
        silence_cnt++;
        if (silence_cnt >= min_silence) {
          state = 0;
          r.is_speech_end = true;
          r.speech_end_frame = frame_cnt;
          r.speech_start_frame = last_start;
          last_end = r.speech_end_frame;
          last_start = -1;
          speech_cnt = 0;
        }
      }
    }
    return r;
  }
};

}  // namespace

// ===================== FRVad =====================

struct FRVad {
  // config
  FRVadConfig cfg;

  // fbank (created once, fed incrementally)
  knf::FbankOptions fopts;
  std::unique_ptr<knf::OnlineFbank> fbank;
  int frames_done = 0;        // absolute count of frames already consumed
  bool input_finished = false;

  // cmvn
  std::vector<float> means;   // 80
  std::vector<float> istd;    // 80

  // onnx
  std::unique_ptr<Ort::Env> env;
  std::unique_ptr<Ort::SessionOptions> sopts;
  std::unique_ptr<Ort::Session> sess;
  Ort::MemoryInfo mem{nullptr};
  std::vector<float> cache;   // [R*P*Co] = 8*128*19
  static constexpr int R = 8, P = 128, Co = 19;
  static constexpr int CHUNK = 30;

  // pending features awaiting a full CHUNK-frame ONNX run (already CMVN'd).
  // Aligned to absolute frame boundaries: pending always starts at an index
  // that is a multiple of CHUNK, so chunk decomposition == vad_check.
  std::vector<float> pending;  // multiple of 80 floats

  // postprocessor + streaming segment emitter (mirrors results_to_timestamps)
  std::unique_ptr<PostProc> pp;
  int seg_start = -1;          // open-segment start frame (-1 = none)
  int last_frame_idx = 0;      // frame_cnt of most recent processed frame
  bool in_speech = false;      // current speech state (post state machine)

  // queue of completed segments (in frame units; converted on poll)
  std::deque<std::pair<int, int>> queue;  // (start_frame, end_frame)

  // --- helpers ---
  void init_fbank_opts() {
    fopts = knf::FbankOptions();
    fopts.frame_opts.samp_freq = 16000;
    fopts.frame_opts.frame_length_ms = 25;
    fopts.frame_opts.frame_shift_ms = 10;
    fopts.frame_opts.dither = 0;
    fopts.frame_opts.snip_edges = true;
    fopts.mel_opts.num_bins = 80;
  }

  void make_postproc() {
    pp.reset(new PostProc(cfg.smooth_window, cfg.speech_threshold, cfg.pad_start,
                          cfg.min_speech_frame, cfg.max_speech_frame,
                          cfg.min_silence_frame));
  }

  void reset_stream_state() {
    fbank.reset(new knf::OnlineFbank(fopts));
    frames_done = 0;
    input_finished = false;
    cache.assign((size_t)R * P * Co, 0.f);
    pending.clear();
    make_postproc();
    seg_start = -1;
    last_frame_idx = 0;
    in_speech = false;
    queue.clear();
  }

  // Run one ONNX inference over Tc frames (feats has Tc*80 floats), carry cache,
  // then push each probability through the postprocessor + segment emitter.
  void run_chunk(const float* feats, int Tc) {
    int64_t fs[3] = {1, Tc, 80};
    int64_t cs[4] = {R, 1, P, Co};
    std::vector<Ort::Value> ins;
    ins.reserve(2);
    ins.push_back(Ort::Value::CreateTensor<float>(
        mem, const_cast<float*>(feats), (size_t)Tc * 80, fs, 3));
    ins.push_back(Ort::Value::CreateTensor<float>(mem, cache.data(),
                                                  cache.size(), cs, 4));
    const char* in_names[] = {"feat", "cache_in"};
    const char* out_names[] = {"probs", "cache_out"};
    auto outs = sess->Run(Ort::RunOptions{nullptr}, in_names, ins.data(), 2,
                          out_names, 2);
    const float* pp_out = outs[0].GetTensorData<float>();
    for (int t = 0; t < Tc; ++t) consume_prob(pp_out[t]);
    const float* nc = outs[1].GetTensorData<float>();
    std::copy(nc, nc + cache.size(), cache.begin());
  }

  // One probability -> postprocessor -> streaming segment emitter.
  // Mirrors vad_check's results_to_timestamps loop exactly:
  //   on is_speech_start: open seg at max(0, speech_start_frame-1)
  //   on is_speech_end:   close seg at max(0, speech_end_frame-1)
  void consume_prob(float prob) {
    FrameResult r = pp->process(prob);
    last_frame_idx = r.frame_idx;
    if (r.is_speech_start) {
      seg_start = std::max(0, r.speech_start_frame - 1);
      in_speech = true;
    } else if (r.is_speech_end) {
      int end = std::max(0, r.speech_end_frame - 1);
      queue.emplace_back(seg_start, end);
      seg_start = -1;
      in_speech = false;
    }
  }

  // Drain newly-ready Fbank frames: CMVN them, append to pending, dispatch full
  // CHUNK-frame ONNX runs. If final==true, also dispatch the short remainder.
  void pump(bool final) {
    int ready = fbank->NumFramesReady();
    for (int t = frames_done; t < ready; ++t) {
      const float* src = fbank->GetFrame(t);
      size_t base = pending.size();
      pending.resize(base + 80);
      for (int d = 0; d < 80; ++d)
        pending[base + d] = (src[d] - means[d]) * istd[d];
    }
    frames_done = ready;

    // Dispatch full CHUNK-frame chunks (boundaries on absolute frame indices).
    int pend_frames = (int)(pending.size() / 80);
    int consumed = 0;
    while (pend_frames - consumed >= CHUNK) {
      run_chunk(&pending[(size_t)consumed * 80], CHUNK);
      consumed += CHUNK;
    }
    if (final && pend_frames - consumed > 0) {
      run_chunk(&pending[(size_t)consumed * 80], pend_frames - consumed);
      consumed = pend_frames;
    }
    if (consumed > 0)
      pending.erase(pending.begin(), pending.begin() + (size_t)consumed * 80);
  }
};

// ===================== C API =====================

extern "C" {

void frv_default_config(FRVadConfig* cfg) {
  if (!cfg) return;
  cfg->speech_threshold = 0.5f;
  cfg->smooth_window = 5;
  cfg->pad_start = 5;
  cfg->min_speech_frame = 20;
  cfg->max_speech_frame = 2000;
  cfg->min_silence_frame = 70;
}

FRVad* frv_create_cfg(const char* model_dir, const FRVadConfig* cfg) {
  if (!model_dir) return nullptr;
  std::unique_ptr<FRVad> v(new FRVad());
  if (cfg) v->cfg = *cfg; else frv_default_config(&v->cfg);

  std::string base(model_dir);
  if (!base.empty() && base.back() == '/') base.pop_back();

  if (!read_bin<float>(base + "/cmvn_means.bin", &v->means) ||
      !read_bin<float>(base + "/cmvn_istd.bin", &v->istd) ||
      v->means.size() < 80 || v->istd.size() < 80) {
    fprintf(stderr, "[frv] failed to load cmvn from %s\n", base.c_str());
    return nullptr;
  }

  try {
    v->env.reset(new Ort::Env(ORT_LOGGING_LEVEL_WARNING, "frv"));
    v->sopts.reset(new Ort::SessionOptions());
    v->sopts->SetIntraOpNumThreads(1);
    std::string model = base + "/firered_vad.onnx";
    v->sess.reset(new Ort::Session(*v->env, model.c_str(), *v->sopts));
    v->mem = Ort::MemoryInfo::CreateCpu(OrtArenaAllocator, OrtMemTypeDefault);
  } catch (const Ort::Exception& e) {
    fprintf(stderr, "[frv] onnxruntime init failed: %s\n", e.what());
    return nullptr;
  }

  v->init_fbank_opts();
  v->reset_stream_state();
  return v.release();
}

FRVad* frv_create(const char* model_dir) {
  return frv_create_cfg(model_dir, nullptr);
}

void frv_accept_int16(FRVad* v, const int16_t* samples, int n) {
  if (!v || !samples || n <= 0) return;
  // int16 magnitude as float, exactly as FireRed feeds knf.
  std::vector<float> wav((size_t)n);
  for (int i = 0; i < n; ++i) wav[i] = (float)samples[i];
  v->fbank->AcceptWaveform(16000, wav.data(), n);
  v->pump(/*final=*/false);
}

int frv_is_speech(const FRVad* v) {
  return (v && v->in_speech) ? 1 : 0;
}

int frv_poll_segment(FRVad* v, double* start_s, double* end_s) {
  if (!v || v->queue.empty()) return 0;
  auto seg = v->queue.front();
  v->queue.pop_front();
  if (start_s) *start_s = seg.first / 100.0;
  if (end_s) *end_s = seg.second / 100.0;
  return 1;
}

void frv_flush(FRVad* v) {
  if (!v) return;
  if (!v->input_finished) {
    v->fbank->InputFinished();
    v->input_finished = true;
  }
  v->pump(/*final=*/true);
  // Close any still-open segment, mirroring vad_check's trailing:
  //   if (start != -1) end = rs.back().frame_idx - 1; push.
  if (v->seg_start != -1) {
    int end = std::max(0, v->last_frame_idx - 1);
    v->queue.emplace_back(v->seg_start, end);
    v->seg_start = -1;
    v->in_speech = false;
  }
}

void frv_reset(FRVad* v) {
  if (!v) return;
  v->reset_stream_state();
}

void frv_free(FRVad* v) {
  delete v;
}

}  // extern "C"
