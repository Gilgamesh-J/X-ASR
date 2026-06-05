#!/bin/bash
# 把 refiner 模型转成 GGUF + 量化(Q4_K_M ≈ 400MB),供 llama.cpp 后端 / 在线分发。
# 产物:dist/refiner-q4_k_m.gguf —— 上传到模型分发处,app 首次开启 AI 润色时在线下载。
#
# 用法:  ./convert_to_gguf.sh <hf-model-dir> [outdir]
#
# ⚠️ convert_hf_to_gguf.py 需要 **HF 格式** 权重(config.json + HF 布局 safetensors)。
#    ModelScope 上的 MuyuanJ/Qwen3-refiner-0.6B-**MLX** 是 MLX 格式,其 safetensors 不一定
#    能直接转。两条路:
#      (a) 用 refiner 的 HF 原版(若作者发布了非 -MLX 版),直接喂给本脚本;
#      (b) 只有 MLX 版时,先转回 HF:  python -m mlx_lm.convert --hf-path <mlx-dir> --dequantize ...
#          (或找原始 Qwen3-0.6B + 该 refiner 的 LoRA/全参权重)再喂本脚本。
set -euo pipefail
HF_DIR="${1:?用法: convert_to_gguf.sh <hf-model-dir> [outdir]}"
OUT="${2:-$(cd "$(dirname "$0")" && pwd)/dist}"
LLAMA="$(cd "$(dirname "$0")" && pwd)/llama.cpp"

[ -d "$LLAMA" ] || { echo "❌ 先跑 ./build.sh(需要 llama.cpp 的 convert 脚本 + llama-quantize)"; exit 1; }
mkdir -p "$OUT"

echo "== HF safetensors → GGUF (f16) =="
python3 "$LLAMA/convert_hf_to_gguf.py" "$HF_DIR" --outfile "$OUT/refiner-f16.gguf" --outtype f16

echo "== quantize → Q4_K_M =="
QUANT="$(find "$LLAMA/build" -name 'llama-quantize' -type f | head -1)"
[ -n "$QUANT" ] || { echo "❌ 没找到 llama-quantize,确认 build.sh 成功"; exit 1; }
"$QUANT" "$OUT/refiner-f16.gguf" "$OUT/refiner-q4_k_m.gguf" Q4_K_M

echo "✅ $OUT/refiner-q4_k_m.gguf"
ls -lh "$OUT/refiner-q4_k_m.gguf"
echo "   验证一下质量没掉太多(对比 refiner_eval 的结果):"
echo "   $LLAMA/build/bin/llama-cli -m $OUT/refiner-q4_k_m.gguf -p \"...\" -no-cnv"
