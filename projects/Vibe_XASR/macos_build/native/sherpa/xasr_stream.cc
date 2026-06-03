// xasr_stream.cc
// Native (no Python) streaming ASR for the X-ASR streaming zipformer2 transducer
// using the sherpa-onnx C API (v1.13.2). Apple Silicon arm64.
//
// Reads a raw little-endian int16 mono 16 kHz PCM file, runs the streaming
// transducer decode loop, and prints the final recognized text.
//
// Expected to match the Python sherpa_onnx reference:
//   哈喽今天天气怎么样？今天天气怎么样？哈喽，一二三四五
//
// Build/run commands are in build.sh next to this file.

#include <cstdint>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <string>
#include <vector>

#include "sherpa-onnx/c-api/c-api.h"

static std::vector<int16_t> ReadS16(const std::string &path) {
  std::ifstream f(path, std::ios::binary | std::ios::ate);
  if (!f) {
    fprintf(stderr, "ERROR: cannot open audio file: %s\n", path.c_str());
    exit(1);
  }
  std::streamsize n = f.tellg();
  f.seekg(0);
  std::vector<int16_t> v(static_cast<size_t>(n) / sizeof(int16_t));
  f.read(reinterpret_cast<char *>(v.data()), n);
  return v;
}

int main(int argc, char **argv) {
  // ---- Paths (overridable via argv) ----
  const char *kModelDir =
      "/path/to/xasr_workspace/"
      "vad_asr_demo/models/asr";
  const char *kAudio =
      "/path/to/xasr_workspace/"
      "xasr_macos_build/models/firered/mic_test.s16";

  std::string model_dir = (argc > 1) ? argv[1] : kModelDir;
  std::string audio = (argc > 2) ? argv[2] : kAudio;
  // model_type: "" => auto-detect from onnx metadata; "zipformer2" => explicit.
  std::string model_type = (argc > 3) ? argv[3] : "zipformer2";

  std::string encoder = model_dir + "/encoder-960ms.onnx";
  std::string decoder = model_dir + "/decoder-960ms.onnx";
  std::string joiner = model_dir + "/joiner-960ms.onnx";
  std::string tokens = model_dir + "/tokens.txt";

  const int32_t kSampleRate = 16000;

  // ---- Configure the streaming transducer recognizer ----
  SherpaOnnxOnlineRecognizerConfig config;
  memset(&config, 0, sizeof(config));

  config.feat_config.sample_rate = kSampleRate;
  config.feat_config.feature_dim = 80;

  config.model_config.transducer.encoder = encoder.c_str();
  config.model_config.transducer.decoder = decoder.c_str();
  config.model_config.transducer.joiner = joiner.c_str();
  config.model_config.tokens = tokens.c_str();
  config.model_config.num_threads = 2;
  config.model_config.provider = "cpu";
  config.model_config.debug = 0;
  config.model_config.model_type = model_type.c_str();  // "" or "zipformer2"

  config.decoding_method = "greedy_search";
  config.max_active_paths = 4;
  config.enable_endpoint = 0;  // single utterance, drain manually

  fprintf(stderr,
          "[config] encoder=%s\n[config] model_type='%s' num_threads=%d "
          "provider=%s decoding=%s\n",
          encoder.c_str(), model_type.c_str(), config.model_config.num_threads,
          config.model_config.provider, config.decoding_method);

  const SherpaOnnxOnlineRecognizer *recognizer =
      SherpaOnnxCreateOnlineRecognizer(&config);
  if (!recognizer) {
    fprintf(stderr, "ERROR: failed to create OnlineRecognizer\n");
    return 1;
  }

  const SherpaOnnxOnlineStream *stream =
      SherpaOnnxCreateOnlineStream(recognizer);
  if (!stream) {
    fprintf(stderr, "ERROR: failed to create OnlineStream\n");
    return 1;
  }

  // ---- Load audio, int16 -> float32 in [-1, 1] ----
  std::vector<int16_t> pcm = ReadS16(audio);
  std::vector<float> samples(pcm.size());
  for (size_t i = 0; i < pcm.size(); ++i) {
    samples[i] = static_cast<float>(pcm[i]) / 32768.0f;
  }
  fprintf(stderr, "[audio] %s : %zu samples (%.2f s)\n", audio.c_str(),
          samples.size(), samples.size() / static_cast<double>(kSampleRate));

  // ---- Feed waveform ----
  SherpaOnnxOnlineStreamAcceptWaveform(stream, kSampleRate, samples.data(),
                                       static_cast<int32_t>(samples.size()));

  // ---- Streaming decode loop ----
  while (SherpaOnnxIsOnlineStreamReady(recognizer, stream)) {
    SherpaOnnxDecodeOnlineStream(recognizer, stream);
  }

  // ---- Tail padding + InputFinished, then drain ----
  // The X-ASR zipformer2 chunk is ~0.96 s (decode_chunk_len=96), so 1.0 s of
  // trailing zeros is needed to flush the final frames. This matches the
  // Python reference (vibe_ime engine: tail_pad=1.0).
  std::vector<float> tail(kSampleRate, 0.0f);  // 1.0 s of zeros
  SherpaOnnxOnlineStreamAcceptWaveform(stream, kSampleRate, tail.data(),
                                       static_cast<int32_t>(tail.size()));
  SherpaOnnxOnlineStreamInputFinished(stream);
  while (SherpaOnnxIsOnlineStreamReady(recognizer, stream)) {
    SherpaOnnxDecodeOnlineStream(recognizer, stream);
  }

  // ---- Final result ----
  const SherpaOnnxOnlineRecognizerResult *result =
      SherpaOnnxGetOnlineStreamResult(recognizer, stream);

  printf("NATIVE: %s\n", (result && result->text) ? result->text : "");

  SherpaOnnxDestroyOnlineRecognizerResult(result);
  SherpaOnnxDestroyOnlineStream(stream);
  SherpaOnnxDestroyOnlineRecognizer(recognizer);
  return 0;
}
