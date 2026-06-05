#!/bin/bash
# 构建 llama.cpp 的 libllama(Metal)供 Vibe XASR 的「AI 润色(Beta)」后端用。
# 产物 → native/llama/dist/{include/*.h, lib/libllama.dylib + libggml*.dylib}
# 之后用 VIBE_LLAMA=1 构建 app 才会接入(见 Package.swift)。不跑此脚本时 app 照常构建,
# AI 润色后端不可用(Beta 开关为安全 no-op)。
#
# 用法:  ./build.sh           # clone + build(默认 master)
#        LLAMA_TAG=b4000 ./build.sh   # pin 某个 release tag(推荐:可复现)
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
DIST="$HERE/dist"
SRC="$HERE/llama.cpp"
REPO="https://github.com/ggml-org/llama.cpp.git"
TAG="${LLAMA_TAG:-master}"

if [ ! -d "$SRC" ]; then
  echo "== clone llama.cpp ($TAG) =="
  git clone --depth 1 -b "$TAG" "$REPO" "$SRC"
fi

echo "== cmake configure (Metal, shared, embedded shader) =="
cmake -S "$SRC" -B "$SRC/build" \
  -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_SHARED_LIBS=ON \
  -DGGML_METAL=ON \
  -DGGML_METAL_EMBED_LIBRARY=ON \
  -DLLAMA_BUILD_TESTS=OFF \
  -DLLAMA_BUILD_EXAMPLES=OFF \
  -DLLAMA_BUILD_SERVER=OFF \
  -DLLAMA_CURL=OFF

echo "== build(只编 libllama + quantize 工具,跳过 examples/app — 它们的无关链接会失败)=="
cmake --build "$SRC/build" --config Release -j"$(sysctl -n hw.ncpu)" --target llama llama-quantize

echo "== stage headers + dylibs → dist/ =="
mkdir -p "$DIST/include" "$DIST/lib"
cp "$SRC/include/llama.h" "$DIST/include/"
cp "$SRC/ggml/include/"*.h "$DIST/include/" 2>/dev/null || true
# libllama(versioned)+ 全套 libggml*,排除 examples 的 *-impl;补 unversioned 链接别名给 ld -lllama。
find "$SRC/build/bin" -maxdepth 1 \( -name "libllama.*.dylib" -o -name "libggml*.dylib" \) ! -name "*-impl.dylib" -exec cp {} "$DIST/lib/" \;
( cd "$DIST/lib" && [ -f libllama.0.dylib ] && ln -sf libllama.0.dylib libllama.dylib )

echo "✅ headers → $DIST/include ; dylibs → $DIST/lib"
ls -1 "$DIST/lib"
echo
echo "下一步:"
echo "  1) 转换模型:  ./convert_to_gguf.sh <hf-model-dir>   → dist/refiner-q4_k_m.gguf"
echo "  2) 构建 app:  VIBE_LLAMA=1 ../app/build_app.sh        (或 VIBE_LLAMA=1 swift build)"
echo "  注:打包时需把 dist/lib/*.dylib 拷进 .app/Contents/Frameworks 并签名(同 sherpa 的处理)。"
