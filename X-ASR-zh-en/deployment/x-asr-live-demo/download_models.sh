#!/bin/sh
# Download the weights needed to run (none are shipped in git).
#   1) ASR : X-ASR-zh-en streaming zipformer chunk-960ms (zh-en + punctuation);
#            falls back to a public zipformer if hf is unavailable.
#   2) VAD : silero_vad.onnx (silero backend, core)
#   3) VAD : FireRedVAD weights (optional; used by the default --vad firered;
#            if missing, the demo auto-falls back to silero)
set -e
cd "$(dirname "$0")"
mkdir -p models/asr models/firered_vad

# ---------------------------------------------------------------- 1) ASR ---- #
try_xasr() {
  command -v hf >/dev/null 2>&1 || { echo "(no hf CLI: pip install -U 'huggingface_hub[cli]')"; return 1; }
  echo ">>> downloading X-ASR-zh-en chunk-960ms (HuggingFace: GilgameshWind/X-ASR-zh-en)"
  hf download GilgameshWind/X-ASR-zh-en \
    --include "deployment/models/chunk-960ms-model/*" --local-dir .hf_xasr || return 1
  D=.hf_xasr/deployment/models/chunk-960ms-model
  cp -f "$D/encoder-960ms.onnx" "$D/decoder-960ms.onnx" \
        "$D/joiner-960ms.onnx" "$D/tokens.txt" models/asr/
  echo ">>> X-ASR ready in models/asr/  (--model-type auto-detects zipformer2)"
}

BASE="https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models"
PUB="sherpa-onnx-streaming-zipformer-bilingual-zh-en-2023-02-20"
try_public() {
  echo ">>> fallback: downloading public streaming zipformer ($PUB)"
  curl -fL --retry 3 -o "models/$PUB.tar.bz2" "$BASE/$PUB.tar.bz2"
  tar xjf "models/$PUB.tar.bz2" -C models/ && rm -f "models/$PUB.tar.bz2"
  rm -rf models/asr && mv "models/$PUB" models/asr
}

try_xasr || try_public || { echo "!! both ASR methods failed, see README"; exit 1; }

# -------------------------------------------------------------- 2) silero --- #
SILERO_URL="$BASE/silero_vad.onnx"
if [ -f models/silero_vad.onnx ]; then
  echo ">>> silero_vad.onnx already present, skipping"
else
  echo ">>> downloading silero_vad.onnx"
  curl -fL --retry 3 -o models/silero_vad.onnx "$SILERO_URL"
fi

# ------------------------------------------------------- 3) FireRedVAD (opt) -- #
# Goal: models/firered_vad/ contains model.pth.tar and cmvn.ark. Failure is fine --
# the runtime auto-falls back to silero.
if [ -f models/firered_vad/model.pth.tar ]; then
  echo ">>> FireRedVAD weights already present, skipping"
elif command -v hf >/dev/null 2>&1; then
  echo ">>> downloading FireRedVAD weights (HuggingFace: FireRedTeam/FireRedVAD)"
  hf download FireRedTeam/FireRedVAD --local-dir models/firered_vad \
    || echo "(FireRedVAD download failed; safe to skip: --vad firered auto-falls back to silero)"
else
  echo "(no hf CLI, skipping FireRedVAD weights. --vad firered will auto-fall back to silero.)"
  echo "  manual (HF)        : huggingface-cli download FireRedTeam/FireRedVAD --local-dir models/firered_vad"
  echo "  manual (ModelScope): modelscope download --model xukaituo/FireRedVAD --local_dir models/firered_vad"
  echo "  ensure you end up with: models/firered_vad/model.pth.tar and models/firered_vad/cmvn.ark"
fi

echo ""; echo "models/asr/:"; ls -1 models/asr
echo "run:  python live_asr.py --wav test.wav   or   python live_asr.py   (mic + FireRedVAD by default)"
