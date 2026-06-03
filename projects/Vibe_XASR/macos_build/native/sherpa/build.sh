#!/bin/bash
# Build + run the native X-ASR streaming transducer CLI (sherpa-onnx C API).
# macOS arm64. Self-contained: uses sherpa-onnx's own bundled onnxruntime 1.24.4.
set -euo pipefail

HERE="/path/to/xasr_workspace/xasr_macos_build/native/sherpa"
DIST="$HERE/dist/sherpa-onnx-v1.13.2-osx-arm64-shared"
INC="$HERE/include"          # vendored headers: sherpa-onnx/c-api/c-api.h
LIB="$DIST/lib"              # libsherpa-onnx-c-api.dylib + libonnxruntime.1.24.4.dylib

clang++ -std=c++17 -O2 -arch arm64 \
  -I"$INC" \
  "$HERE/xasr_stream.cc" \
  -L"$LIB" \
  -lsherpa-onnx-c-api \
  -Wl,-rpath,"$LIB" \
  -o "$HERE/xasr_stream"

echo "[built] $HERE/xasr_stream"
"$HERE/xasr_stream" "$@"
