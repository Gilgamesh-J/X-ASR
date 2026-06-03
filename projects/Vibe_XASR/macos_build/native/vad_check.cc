// Native FireRedVAD parity check (C++): int16 samples -> knf fbank -> CMVN ->
// firered_vad.onnx (onnxruntime, streaming cache) -> postprocessor -> segments.
// Expected to match Python: [(1.01, 4.97)].
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <deque>
#include <fstream>
#include <string>
#include <vector>

#include "kaldi-native-fbank/csrc/online-feature.h"
#include "onnxruntime_cxx_api.h"

template <typename T>
static std::vector<T> read_bin(const std::string &p) {
  std::ifstream f(p, std::ios::binary | std::ios::ate);
  if (!f) { fprintf(stderr, "cannot open %s\n", p.c_str()); exit(1); }
  std::streamsize n = f.tellg();
  f.seekg(0);
  std::vector<T> v(n / sizeof(T));
  f.read(reinterpret_cast<char *>(v.data()), n);
  return v;
}

// ---- StreamVadPostprocessor port (deterministic state machine) ----
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
      : smoothN(std::max(1, sN)), pad_start(std::max(std::max(1, sN), ps)),
        min_speech(msp), max_speech(mxs), min_silence(msl), thr(t) {}

  FrameResult process(float raw) {
    frame_cnt++;
    float sm = raw;
    if (smoothN > 1) {
      win.push_back(raw); win_sum += raw;
      if ((int)win.size() > smoothN) { win_sum -= win.front(); win.pop_front(); }
      sm = (float)(win_sum / win.size());
    }
    int is_speech = (sm >= thr) ? 1 : 0;
    FrameResult r; r.frame_idx = frame_cnt;

    if (hit_max) {
      r.is_speech_start = true; r.speech_start_frame = frame_cnt;
      last_start = frame_cnt; hit_max = false;
    }
    if (state == 0) {
      if (is_speech) { state = 1; speech_cnt++; }
      else { silence_cnt++; speech_cnt = 0; }
    } else if (state == 1) {
      if (is_speech) {
        speech_cnt++;
        if (speech_cnt >= min_speech) {
          state = 2; r.is_speech_start = true;
          r.speech_start_frame = std::max({1, frame_cnt - speech_cnt + 1 - pad_start, last_end + 1});
          last_start = r.speech_start_frame; silence_cnt = 0;
        }
      } else { state = 0; silence_cnt = 1; speech_cnt = 0; }
    } else if (state == 2) {
      speech_cnt++;
      if (is_speech) {
        silence_cnt = 0;
        if (speech_cnt >= max_speech) {
          hit_max = true; speech_cnt = 0; r.is_speech_end = true;
          r.speech_end_frame = frame_cnt; r.speech_start_frame = last_start;
          last_start = -1; last_end = r.speech_end_frame;
        }
      } else { state = 3; silence_cnt++; }
    } else {  // POSSIBLE_SILENCE
      speech_cnt++;
      if (is_speech) {
        state = 2; silence_cnt = 0;
        if (speech_cnt >= max_speech) {
          hit_max = true; speech_cnt = 0; r.is_speech_end = true;
          r.speech_end_frame = frame_cnt; r.speech_start_frame = last_start;
          last_start = -1; last_end = r.speech_end_frame;
        }
      } else {
        silence_cnt++;
        if (silence_cnt >= min_silence) {
          state = 0; r.is_speech_end = true; r.speech_end_frame = frame_cnt;
          r.speech_start_frame = last_start; last_end = r.speech_end_frame;
          last_start = -1; speech_cnt = 0;
        }
      }
    }
    return r;
  }
};

int main(int argc, char **argv) {
  std::string base = argc > 1 ? argv[1] : "models/firered";

  // 1) int16 samples -> float (int16 magnitude, as FireRed feeds knf)
  auto s16 = read_bin<int16_t>(base + "/mic_test.s16");
  std::vector<float> wav(s16.size());
  for (size_t i = 0; i < s16.size(); ++i) wav[i] = (float)s16[i];

  // 2) knf fbank (80-mel, 25/10ms, dither 0, snip_edges)
  knf::FbankOptions opts;
  opts.frame_opts.samp_freq = 16000;
  opts.frame_opts.frame_length_ms = 25;
  opts.frame_opts.frame_shift_ms = 10;
  opts.frame_opts.dither = 0;
  opts.frame_opts.snip_edges = true;
  opts.mel_opts.num_bins = 80;
  knf::OnlineFbank fbank(opts);
  fbank.AcceptWaveform(16000, wav.data(), (int)wav.size());
  fbank.InputFinished();
  int T = fbank.NumFramesReady();
  std::vector<float> feats((size_t)T * 80);
  for (int t = 0; t < T; ++t)
    std::copy(fbank.GetFrame(t), fbank.GetFrame(t) + 80, &feats[(size_t)t * 80]);

  // 3) CMVN
  auto means = read_bin<float>(base + "/cmvn_means.bin");
  auto istd = read_bin<float>(base + "/cmvn_istd.bin");
  for (int t = 0; t < T; ++t)
    for (int d = 0; d < 80; ++d)
      feats[(size_t)t * 80 + d] = (feats[(size_t)t * 80 + d] - means[d]) * istd[d];

  // 4) onnx streaming (30-frame chunks, carry cache)
  const int R = 8, P = 128, Co = 19;
  Ort::Env env(ORT_LOGGING_LEVEL_WARNING, "vad");
  Ort::SessionOptions so; so.SetIntraOpNumThreads(1);
  Ort::Session sess(env, (base + "/firered_vad.onnx").c_str(), so);
  auto mem = Ort::MemoryInfo::CreateCpu(OrtArenaAllocator, OrtMemTypeDefault);
  std::vector<float> cache((size_t)R * P * Co, 0.f);
  std::vector<float> probs; probs.reserve(T);
  const char *in_names[] = {"feat", "cache_in"};
  const char *out_names[] = {"probs", "cache_out"};
  for (int i = 0; i < T; i += 30) {
    int Tc = std::min(30, T - i);
    int64_t fs[3] = {1, Tc, 80};
    int64_t cs[4] = {R, 1, P, Co};
    std::vector<Ort::Value> ins;
    ins.push_back(Ort::Value::CreateTensor<float>(mem, &feats[(size_t)i * 80], (size_t)Tc * 80, fs, 3));
    ins.push_back(Ort::Value::CreateTensor<float>(mem, cache.data(), cache.size(), cs, 4));
    auto outs = sess.Run(Ort::RunOptions{nullptr}, in_names, ins.data(), 2, out_names, 2);
    float *pp = outs[0].GetTensorMutableData<float>();
    for (int t = 0; t < Tc; ++t) probs.push_back(pp[t]);
    float *nc = outs[1].GetTensorMutableData<float>();
    std::copy(nc, nc + cache.size(), cache.begin());
  }

  // 5) postprocessor -> segments
  PostProc pp(5, 0.5f, 5, 20, 2000, 70);
  std::vector<FrameResult> rs;
  for (float p : probs) rs.push_back(pp.process(p));
  // results_to_timestamps
  printf("T=%d frames, %zu probs\n", T, probs.size());
  std::vector<std::pair<double, double>> segs;
  int start = -1, end = -1;
  for (auto &r : rs) {
    if (r.is_speech_start) { start = std::max(0, r.speech_start_frame - 1); end = -1; }
    else if (r.is_speech_end) { end = std::max(0, r.speech_end_frame - 1); segs.push_back({start / 100.0, end / 100.0}); start = -1; end = -1; }
  }
  if (start != -1) { end = rs.back().frame_idx - 1; segs.push_back({start / 100.0, end / 100.0}); }
  printf("native segments: [");
  for (size_t i = 0; i < segs.size(); ++i)
    printf("%s(%.2f, %.2f)", i ? ", " : "", segs[i].first, segs[i].second);
  printf("]\n");
  return 0;
}
