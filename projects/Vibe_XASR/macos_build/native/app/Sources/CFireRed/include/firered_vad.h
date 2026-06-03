// firered_vad.h — Streaming C API for FireRedVAD (native macOS / arm64).
//
// Pipeline (byte-identical to native/vad_check.cc):
//   int16 samples -> knf OnlineFbank (80 mel, 25/10 ms, dither 0, snip_edges)
//   -> CMVN (subtract means, multiply inverse_std)
//   -> firered_vad.onnx (onnxruntime) run in 30-frame chunks carrying a
//      [8,1,128,19] streaming cache
//   -> StreamVadPostprocessor state machine -> speech segments (seconds).
//
// True streaming: feed arbitrary-length int16 chunks via frv_accept_int16().
// The Fbank is driven incrementally; ONNX runs once per completed 30-frame
// chunk (so cache decomposition matches vad_check exactly). Completed
// (start,end) segments are queued and drained with frv_poll_segment().
//
// Frames are 10 ms (100 fps); segment times are in seconds.

#ifndef FIRERED_VAD_H_
#define FIRERED_VAD_H_

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct FRVad FRVad;

// Postprocessor / threshold configuration. Defaults match vad_check.cc:
//   speech_threshold = 0.5, smooth_window = 5, pad_start = 5,
//   min_speech_frame = 20, max_speech_frame = 2000, min_silence_frame = 70.
// Frames are 10 ms. Pass NULL to frv_create_cfg (or use frv_create) for
// defaults.
typedef struct FRVadConfig {
  float speech_threshold;   // probability threshold (default 0.5)
  int   smooth_window;      // moving-average window in frames (default 5)
  int   pad_start;          // start padding in frames (default 5)
  int   min_speech_frame;   // min speech run to confirm onset (default 20)
  int   max_speech_frame;   // forced cut length (default 2000)
  int   min_silence_frame;  // min trailing silence to end (default 70)
} FRVadConfig;

// Fill *cfg with the defaults above.
void frv_default_config(FRVadConfig* cfg);

// Create a detector. model_dir must contain:
//   firered_vad.onnx, cmvn_means.bin (80 float32), cmvn_istd.bin (80 float32).
// Returns NULL on failure (missing files / bad model). Uses default config.
FRVad* frv_create(const char* model_dir);

// Same as frv_create but with an explicit config (cfg may be NULL = defaults).
FRVad* frv_create_cfg(const char* model_dir, const FRVadConfig* cfg);

// Accept an arbitrary-length chunk of int16 PCM (16 kHz, mono). May emit zero
// or more completed segments internally; drain them with frv_poll_segment().
void frv_accept_int16(FRVad* v, const int16_t* samples, int n);

// 1 if currently inside a confirmed speech segment (post state machine), else 0.
int frv_is_speech(const FRVad* v);

// Pop one completed segment. Returns 1 and fills *start_s/*end_s (seconds) if a
// segment is queued, else returns 0. Call in a loop to drain all queued ones.
int frv_poll_segment(FRVad* v, double* start_s, double* end_s);

// Finalize: flush the Fbank, process any remaining frames, and close out an
// in-flight (open) segment. Call on stop. Queued segments remain pollable.
void frv_flush(FRVad* v);

// Reset all streaming state (Fbank, cache, postprocessor, queue) so the same
// instance can process a fresh utterance.
void frv_reset(FRVad* v);

// Destroy the detector.
void frv_free(FRVad* v);

#ifdef __cplusplus
}  // extern "C"
#endif

#endif  // FIRERED_VAD_H_
