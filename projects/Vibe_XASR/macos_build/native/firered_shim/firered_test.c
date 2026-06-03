// firered_test.c — frame-parity test for the streaming FireRedVAD C API.
//
// Mode A: one big frv_accept_int16(all samples) then frv_flush.
// Mode B: streaming frv_accept_int16(1600 samples) repeatedly, polling after
//         each accept, then frv_flush.
// Both must reproduce [(1.01, 4.97)] (A exact; B within <= 1 frame, +-0.01 s).
//
// argv[1] (optional): model_dir (contains firered_vad.onnx, cmvn_*.bin,
// mic_test.s16). Defaults to the build's models/firered.

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "firered_vad.h"

#define MAX_SEGS 256

typedef struct {
  double s[MAX_SEGS], e[MAX_SEGS];
  int n;
} Segs;

static void drain(FRVad* v, Segs* out) {
  double s, e;
  while (frv_poll_segment(v, &s, &e)) {
    if (out->n < MAX_SEGS) {
      out->s[out->n] = s;
      out->e[out->n] = e;
      out->n++;
    }
  }
}

static void print_segs(const char* tag, const Segs* g) {
  printf("%s: [", tag);
  for (int i = 0; i < g->n; ++i)
    printf("%s(%.2f, %.2f)", i ? ", " : "", g->s[i], g->e[i]);
  printf("]\n");
}

// Read whole file of int16 samples. Returns malloc'd buffer (caller frees) and
// sets *count, or NULL on failure.
static int16_t* read_s16(const char* path, long* count) {
  FILE* f = fopen(path, "rb");
  if (!f) return NULL;
  fseek(f, 0, SEEK_END);
  long bytes = ftell(f);
  fseek(f, 0, SEEK_SET);
  if (bytes <= 0) { fclose(f); return NULL; }
  int16_t* buf = (int16_t*)malloc((size_t)bytes);
  if (!buf) { fclose(f); return NULL; }
  size_t got = fread(buf, 1, (size_t)bytes, f);
  fclose(f);
  *count = (long)(got / sizeof(int16_t));
  return buf;
}

// Compare segs against expected [(1.01,4.97)] within tolerance (seconds).
static int matches_expected(const Segs* g, double tol) {
  const double es = 1.01, ee = 4.97;
  if (g->n != 1) return 0;
  double ds = g->s[0] - es, de = g->e[0] - ee;
  if (ds < 0) ds = -ds;
  if (de < 0) de = -de;
  return ds <= tol && de <= tol;
}

int main(int argc, char** argv) {
  const char* model_dir =
      (argc > 1) ? argv[1]
                 : "/path/to/workspace/"
                   "xasr_workspace/xasr_macos_build/models/firered";

  char wav_path[2048];
  snprintf(wav_path, sizeof(wav_path), "%s/mic_test.s16", model_dir);

  long count = 0;
  int16_t* samples = read_s16(wav_path, &count);
  if (!samples) {
    fprintf(stderr, "FAIL: cannot read %s\n", wav_path);
    return 2;
  }
  printf("loaded %ld int16 samples (%.2f s @16k)\n", count, count / 16000.0);

  // ---------------- Mode A: one big accept ----------------
  Segs ga = {0};
  {
    FRVad* v = frv_create(model_dir);
    if (!v) { fprintf(stderr, "FAIL: frv_create (A)\n"); free(samples); return 2; }
    frv_accept_int16(v, samples, (int)count);
    drain(v, &ga);
    frv_flush(v);
    drain(v, &ga);
    frv_free(v);
  }
  print_segs("mode A (one big accept)", &ga);

  // ---------------- Mode B: streaming 1600-sample chunks ----------------
  Segs gb = {0};
  {
    FRVad* v = frv_create(model_dir);
    if (!v) { fprintf(stderr, "FAIL: frv_create (B)\n"); free(samples); return 2; }
    const int CH = 1600;  // 100 ms @16k
    int is_speech_seen = 0;
    for (long off = 0; off < count; off += CH) {
      int n = (int)(count - off < CH ? count - off : CH);
      frv_accept_int16(v, samples + off, n);
      if (frv_is_speech(v)) is_speech_seen = 1;
      drain(v, &gb);
    }
    frv_flush(v);
    drain(v, &gb);
    printf("mode B: frv_is_speech went high during stream: %s\n",
           is_speech_seen ? "yes" : "no");
    frv_free(v);
  }
  print_segs("mode B (1600-sample stream)", &gb);

  free(samples);

  // ---------------- Verdict ----------------
  printf("expected: [(1.01, 4.97)]\n");
  int okA = matches_expected(&ga, 1e-9);   // mode A: exact
  int okB = matches_expected(&gb, 0.0101);  // mode B: within 1 frame (0.01 s)
  printf("mode A %s (exact)\n", okA ? "MATCH" : "MISMATCH");
  printf("mode B %s (<= 1 frame)\n", okB ? "MATCH" : "MISMATCH");

  if (okA && okB) {
    printf("PASS\n");
    return 0;
  }
  printf("FAIL\n");
  return 1;
}
