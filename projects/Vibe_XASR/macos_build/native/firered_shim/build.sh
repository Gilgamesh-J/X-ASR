#!/usr/bin/env bash
# Build the FireRedVAD shim (firered_vad.cc) + the C parity test
# (firered_test.c), then run it and report PASS/FAIL.
#
# Mirrors the vad_check build recipe: compile kissfft C objects, then link the
# knf csrc sources + onnxruntime. The shim is C++ (pulls in knf + onnxruntime);
# the test is plain C; final link uses clang++ so libc++/onnxruntime resolve.

set -euo pipefail

BUILD="/path/to/xasr_workspace/xasr_macos_build"
SHIM="$BUILD/native/firered_shim"
KISS="$BUILD/native/third_party/kissfft"
K="$BUILD/native/third_party/kaldi-native-fbank/kaldi-native-fbank/csrc"
KNF_INC="$BUILD/native/third_party/kaldi-native-fbank"
ORT="$BUILD/native/third_party/onnxruntime"
MODELS="$BUILD/models/firered"

cd "$SHIM"
echo "== building in $SHIM =="

# 1) kissfft C objects
clang -O2 -arch arm64 -I "$KISS" -c "$KISS/kiss_fft.c"  -o kiss_fft.o
clang -O2 -arch arm64 -I "$KISS" -c "$KISS/kiss_fftr.c" -o kiss_fftr.o

KNF_SRCS=(
  "$K/feature-fbank.cc" "$K/feature-functions.cc" "$K/feature-mfcc.cc"
  "$K/feature-raw-audio-samples.cc" "$K/feature-window.cc" "$K/istft.cc"
  "$K/kaldi-math.cc" "$K/log.cc" "$K/mel-computations.cc"
  "$K/online-feature.cc" "$K/rfft.cc" "$K/stft.cc" "$K/whisper-feature.cc"
)

# 2) shim object (C++): C interface, C++ internals
clang++ -std=c++17 -O2 -arch arm64 -c "$SHIM/firered_vad.cc" \
  -I "$SHIM" -I "$KNF_INC" -I "$KISS" -I "$ORT/include" \
  -o firered_vad.o

# 3) test object (plain C)
clang -std=c11 -O2 -arch arm64 -c "$SHIM/firered_test.c" \
  -I "$SHIM" -o firered_test.o

# 4) link everything (clang++ for libc++ + onnxruntime)
clang++ -std=c++17 -O2 -arch arm64 \
  firered_test.o firered_vad.o "${KNF_SRCS[@]}" kiss_fft.o kiss_fftr.o \
  -I "$KNF_INC" -I "$KISS" -I "$ORT/include" \
  -L "$ORT/lib" -lonnxruntime -Wl,-rpath,"$ORT/lib" \
  -o firered_test

echo "== built: $SHIM/firered_test =="
echo "== running test (model_dir=$MODELS) =="
echo

set +e
"$SHIM/firered_test" "$MODELS"
RC=$?
set -e

echo
if [ "$RC" -eq 0 ]; then
  echo ">>> BUILD+TEST RESULT: PASS"
else
  echo ">>> BUILD+TEST RESULT: FAIL (exit $RC)"
fi
exit "$RC"
