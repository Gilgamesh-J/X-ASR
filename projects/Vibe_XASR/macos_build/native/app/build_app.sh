#!/usr/bin/env bash
# build_app.sh — build VibeIME (SwiftPM, release) and assemble an ad-hoc-signed
# "Vibe XASR.app" bundle under <B>/native/dist/.
#
# Layout produced:
#   Vibe XASR.app/
#     Contents/
#       Info.plist                      (from native/app/Resources/Info.plist)
#       MacOS/VibeIME                    (the built release executable)
#       Frameworks/                      (sherpa + onnxruntime dylibs)
#         libsherpa-onnx-c-api.dylib
#         libsherpa-onnx-cxx-api.dylib
#         libonnxruntime.1.24.4.dylib
#         libonnxruntime.dylib -> libonnxruntime.1.24.4.dylib
#       Resources/
#         asr/      (encoder/decoder/joiner-960ms.onnx + tokens.txt)
#         firered/  (firered_vad.onnx + cmvn_means.bin + cmvn_istd.bin + metas)
#         ui/       (HTML/JSX mockups — reference only)
#
# The exec already carries an @executable_path/../Frameworks rpath and links
# @rpath/libsherpa-onnx-c-api.dylib + @rpath/libonnxruntime.1.24.4.dylib, so no
# install-name rewriting is required; we ad-hoc sign everything with the
# hardened runtime + entitlements. Developer ID sign + notarize is done later
# (see native/app/sign_notarize.sh) — NOT here.

set -euo pipefail

# B = the macos_build/ root, derived from this script's location (no hardcoded
# absolute path → the repo is portable). build_app.sh lives at native/app/.
B="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
APP_SRC="$B/native/app"
DIST="$B/native/dist"
APP="$DIST/Vibe XASR.app"

SHERPA_LIB="$B/native/sherpa/dist/sherpa-onnx-v1.13.2-osx-universal2-shared/lib"
# AI 润色(Beta)的 libllama 目前只编了 arm64,故 VIBE_LLAMA 打包时降为 arm64-only。
if [ -n "${VIBE_LLAMA:-}" ]; then
  ARCHS="--arch arm64"                           # arm64 only (libllama is arm64)
else
  ARCHS="--arch arm64 --arch x86_64"             # universal2 (Apple Silicon + Intel)
fi
# 960ms ASR model lives OUTSIDE the repo (xasr_workspace/vad_asr_demo). Override
# ASR_SRC to point elsewhere, or fetch from HuggingFace GilgameshWind/X-ASR-zh-en.
ASR_SRC="${ASR_SRC:-$B/../../vad_asr_demo/models/asr}"   # encoder/decoder/joiner-960ms + tokens
FIRED_SRC="$B/models/firered"
UI_SRC="$B/ui"
ENTITLEMENTS="$APP_SRC/Resources/VibeIME.entitlements"
INFO_PLIST="$APP_SRC/Resources/Info.plist"

echo "== [1/6] swift build -c release (universal2) =="
cd "$APP_SRC"
swift build -c release $ARCHS
EXEC="$(swift build -c release $ARCHS --show-bin-path)/VibeIME"
[ -x "$EXEC" ] || { echo "ERROR: built exec not found at $EXEC"; exit 1; }
echo "   built: $EXEC"

echo "== [2/6] assemble bundle skeleton =="
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Frameworks"
mkdir -p "$APP/Contents/Resources"

cp "$EXEC" "$APP/Contents/MacOS/VibeIME"
cp "$INFO_PLIST" "$APP/Contents/Info.plist"

# App icon (referenced by Info.plist CFBundleIconFile = AppIcon) → Launchpad/Dock.
cp "$APP_SRC/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

echo "== [3/6] copy dylibs into Frameworks =="
cp "$SHERPA_LIB/libsherpa-onnx-c-api.dylib"     "$APP/Contents/Frameworks/"
cp "$SHERPA_LIB/libsherpa-onnx-cxx-api.dylib"   "$APP/Contents/Frameworks/"
cp "$SHERPA_LIB/libonnxruntime.1.24.4.dylib"    "$APP/Contents/Frameworks/"
# Provide the unversioned alias too (some loaders look it up by soname).
ln -sf "libonnxruntime.1.24.4.dylib" "$APP/Contents/Frameworks/libonnxruntime.dylib"

# AI 润色(Beta):libllama + ggml(versioned .0 — exec/libllama 依赖 @rpath/lib*.0.dylib;
# install name 全是 @rpath,配合 exec 的 @executable_path/../Frameworks 即可解析)。
if [ -n "${VIBE_LLAMA:-}" ]; then
  LLAMA_LIB="$B/native/llama/dist/lib"
  for d in libllama.0 libggml.0 libggml-base.0 libggml-cpu.0 libggml-blas.0 libggml-metal.0; do
    cp "$LLAMA_LIB/$d.dylib" "$APP/Contents/Frameworks/" && echo "   + $d.dylib"
  done
fi

# Sparkle auto-update framework (universal). The app is NOT sandboxed, so Sparkle's
# XPC services are unnecessary — drop them (smaller bundle, simpler signing).
SPARKLE_FW_SRC="$B/native/third_party/sparkle/Sparkle.framework"
if [ -d "$SPARKLE_FW_SRC" ]; then
  cp -R "$SPARKLE_FW_SRC" "$APP/Contents/Frameworks/"
  rm -rf "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices"
else
  echo "   WARN: Sparkle.framework not found at $SPARKLE_FW_SRC (auto-update will be unavailable)"
fi

echo "== [4/6] copy models + ui into Resources =="
mkdir -p "$APP/Contents/Resources/asr" "$APP/Contents/Resources/firered"
cp "$ASR_SRC/encoder-960ms.onnx" "$ASR_SRC/decoder-960ms.onnx" \
   "$ASR_SRC/joiner-960ms.onnx"  "$ASR_SRC/tokens.txt" \
   "$APP/Contents/Resources/asr/"
# Hotword tokenization needs the (augmented) bpe.vocab. Prefer an official one if
# the model ships it; otherwise reconstruct it from tokens.txt (English hotwords +
# CJK bootstrap). If this fails, hotwords degrade gracefully (Chinese still works
# via the bundled list; English is skipped).
if [ -f "$ASR_SRC/bpe.vocab" ]; then
  cp "$ASR_SRC/bpe.vocab" "$APP/Contents/Resources/asr/"
else
  python3 "$B/../tools/hotwords_eval/make_bpe_vocab.py" \
    "$APP/Contents/Resources/asr/tokens.txt" "$APP/Contents/Resources/asr/bpe.vocab" \
    || echo "   WARN: bpe.vocab generation failed → English hotwords unavailable"
fi
cp "$FIRED_SRC/firered_vad.onnx" "$FIRED_SRC/cmvn_means.bin" "$FIRED_SRC/cmvn_istd.bin" \
   "$APP/Contents/Resources/firered/"
# Optional meta/json + sample (harmless; keeps the dir self-describing).
for f in cmvn.json vad_meta.json mic_test.s16; do
  [ -f "$FIRED_SRC/$f" ] && cp "$FIRED_SRC/$f" "$APP/Contents/Resources/firered/" || true
done
# silero VAD model (selectable alternative to FireRedVAD) → Resources root,
# where ModelPaths.sileroModelPath() resolves it.
SILERO_SRC="$APP_SRC/Resources/silero_vad.onnx"
[ -f "$SILERO_SRC" ] && cp "$SILERO_SRC" "$APP/Contents/Resources/silero_vad.onnx" || \
  echo "   WARN: silero_vad.onnx not found at $SILERO_SRC (silero VAD will be unavailable)"
# 汉字拼音表(同音字纠正用)。缺失则该功能自动跳过。
[ -f "$APP_SRC/Resources/pinyin.txt" ] && cp "$APP_SRC/Resources/pinyin.txt" "$APP/Contents/Resources/pinyin.txt" || \
  echo "   WARN: pinyin.txt not found (homophone correction will be unavailable)"
# AI 润色 GGUF:不再打进安装包 —— 首次启用时由 ModelDownloader 在线下载(进度条 + 来源
# 见「AI 功能」页),装包更小。如需回到内置内测包,设 VIBE_BUNDLE_REFINER=1。
if [ -n "${VIBE_LLAMA:-}" ] && [ -n "${VIBE_BUNDLE_REFINER:-}" ] && [ -f "$B/native/llama/dist/refiner-q4_k_m.gguf" ]; then
  mkdir -p "$APP/Contents/Resources/refiner"
  cp "$B/native/llama/dist/refiner-q4_k_m.gguf" "$APP/Contents/Resources/refiner/"
  echo "   + refiner-q4_k_m.gguf (内置, ~378M, VIBE_BUNDLE_REFINER)"
fi
if [ -d "$UI_SRC" ]; then
  cp -R "$UI_SRC" "$APP/Contents/Resources/ui"
fi

echo "== [5/6] fix rpaths (drop the dev-tree fallback so the bundle is self-contained) =="
# The exec keeps @executable_path/../Frameworks (added at link time). Remove the
# absolute source-tree rpath so the shipped app does not depend on the build dir.
# (Ignore failure if it was already absent.)
install_name_tool -delete_rpath "$SHERPA_LIB" "$APP/Contents/MacOS/VibeIME" 2>/dev/null || true
# Ensure the bundle rpath is present (Package.swift already adds it). Tolerate the
# "already present" case — harmless, and for a universal binary the otool guard
# could misfire and try to re-add it.
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/VibeIME" 2>/dev/null || true

echo "== [6/6] ad-hoc sign (hardened runtime + entitlements) =="
# AMFI's entitlements parser rejects XML comments, so normalize the entitlements
# to a comment-free plist before signing.
ENT_CLEAN="$(mktemp -t vibe_ent).plist"
plutil -convert xml1 -o "$ENT_CLEAN" "$ENTITLEMENTS"

# Sign nested dylibs first (real files only, skip the symlink), then the app.
# Ad-hoc identity "-".
for dylib in "$APP/Contents/Frameworks/"*.dylib; do
  [ -L "$dylib" ] && continue
  codesign -s - --force --options runtime --timestamp=none "$dylib"
done
# Sparkle: sign nested helpers (innermost) first, then the framework.
SPK="$APP/Contents/Frameworks/Sparkle.framework"
if [ -d "$SPK" ]; then
  codesign -s - --force --options runtime --timestamp=none "$SPK/Versions/B/Updater.app"
  codesign -s - --force --options runtime --timestamp=none "$SPK/Versions/B/Autoupdate"
  codesign -s - --force --options runtime --timestamp=none "$SPK"
fi
codesign -s - --force --options runtime --timestamp=none \
  --entitlements "$ENT_CLEAN" \
  "$APP"
rm -f "$ENT_CLEAN"

echo
echo "== verify signature =="
codesign --verify --verbose=2 "$APP" || { echo "WARN: codesign --verify reported issues"; }
echo
echo ">>> assembled: $APP"
echo ">>> exec deps:"
otool -L "$APP/Contents/MacOS/VibeIME" | grep -iE "sherpa|onnxruntime" || true
