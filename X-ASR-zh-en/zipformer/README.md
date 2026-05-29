# X-ASR-zh-en Zipformer Recipe

This directory contains the icefall/Zipformer recipe files used for the released `X-ASR-zh-en` model. It is intended for users who want to inspect the training code, reproduce or adapt the recipe, run decoding, or export checkpoints for deployment.

For ready-to-run sherpa-onnx WebSocket deployment, see [`../deployment/README.md`](../deployment/README.md).

## Directory Layout

```text
zipformer/
|-- README.md
|-- train.py
|-- finetune.py
|-- decode.py
|-- streaming_decode.py
|-- export.py
|-- export-onnx.py
|-- export-onnx-streaming.py
|-- model.py
|-- zipformer.py
|-- data/
|   |-- lang_5000/
|   |   |-- bpe.model
|   |   `-- tokens.txt
|   `-- lang_5000_with_punctuation/
|       |-- bpe_punc.model
|       `-- tokens.txt
`-- checkpoint/
    |-- pretrained.pt
    `-- fintuned_with_punctuation.pt
```

## Checkpoints

| File | Description |
| --- | --- |
| `checkpoint/pretrained.pt` | The base checkpoint obtained from the main X-ASR-zh-en training run. |
| `checkpoint/fintuned_with_punctuation.pt` | A checkpoint fine-tuned from `checkpoint/pretrained.pt` to improve punctuation prediction and true English casing. |

## Data and Checkpoint Mapping

Use the data folder that matches the checkpoint being loaded. In the commands below, replace `/bpe_dir` with the corresponding BPE model path.

| Checkpoint | Matching data folder | BPE model | Tokens | Usage |
| --- | --- | --- | --- | --- |
| `checkpoint/pretrained.pt` | `data/lang_5000/` | `data/lang_5000/bpe.model` | `data/lang_5000/tokens.txt` | Base X-ASR-zh-en checkpoint from the main training run. |
| `checkpoint/fintuned_with_punctuation.pt` | `data/lang_5000_with_punctuation/` | `data/lang_5000_with_punctuation/bpe_punc.model` | `data/lang_5000_with_punctuation/tokens.txt` | Fine-tuned checkpoint for punctuation prediction and true English casing. |

## Training

### Base Training

```bash
python ./zipformer/train.py \
  --world-size 8 \
  --num-epochs 5 \
  --start-epoch 1 \
  --use-bf16 1 \
  --exp-dir /exp_dir \
  --max-duration 3600 \
  --lr-epochs 0.0097 \
  --bpe-model /bpe_dir \
  --num-buckets 40 \
  --keep-last-k 100 \
  --num-workers 4 \
  --on-the-fly-feats True \
  --num-encoder-layers 2,2,4,5,4,2 \
  --feedforward-dim 512,768,1536,2048,1536,768 \
  --encoder-dim 192,256,512,768,512,256 \
  --encoder-unmasked-dim 192,192,256,320,256,192 \
  --causal 1 \
  --chunk-size "8,24,48,96,-1" \
  --left-context-frames "96,128,256,-1"
```

### Fine-tuning for Punctuation and Casing

```bash
python3 ./zipformer/finetune.py \
  --world-size 8 \
  --num-epochs 1 \
  --start-epoch 1 \
  --use-bf16 1 \
  --do-finetune 1 \
  --finetune-ckpt /pretrained.pt \
  --bpe-model /bpe_dir \
  --init-modules encoder_embed,encoder \
  --exp-dir /exp_dir \
  --max-duration 3000 \
  --lr-epochs 0.0097 \
  --num-buckets 40 \
  --keep-last-k 100 \
  --num-workers 4 \
  --on-the-fly-feats True \
  --num-encoder-layers 2,2,4,5,4,2 \
  --feedforward-dim 512,768,1536,2048,1536,768 \
  --encoder-dim 192,256,512,768,512,256 \
  --encoder-unmasked-dim 192,192,256,320,256,192 \
  --causal 1 \
  --chunk-size "8,24,48,96,-1" \
  --left-context-frames "96,128,256,-1" \
  --base-lr 0.0045
```

## Decoding

### Offline Decoding

```bash
./zipformer/decode.py \
  --exp-dir /exp_dir \
  --use-ctc False \
  --use-transducer True \
  --bpe-model /bpe_dir \
  --num-encoder-layers 2,2,4,5,4,2 \
  --feedforward-dim 512,768,1536,2048,1536,768 \
  --encoder-dim 192,256,512,768,512,256 \
  --encoder-unmasked-dim 192,192,256,320,256,192 \
  --causal 1 \
  --use-averaged-model True \
  --decoding-method greedy_search \
  --max-duration 1000 \
  --left-context-frames -1 \
  --chunk-size -1 \
  --avg 3 \
  --epoch 10
```

### Streaming Decoding

```bash
./zipformer/streaming_decode.py \
  --exp-dir /exp_dir \
  --use-ctc 0 \
  --use-transducer 1 \
  --bpe-model /bpe_dir \
  --num-encoder-layers 2,2,4,5,4,2 \
  --feedforward-dim 512,768,1536,2048,1536,768 \
  --encoder-dim 192,256,512,768,512,256 \
  --encoder-unmasked-dim 192,192,256,320,256,192 \
  --causal 1 \
  --use-averaged-model True \
  --decoding-method greedy_search \
  --num-decode-streams 1000 \
  --left-context-frames 256 \
  --chunk-size 96 \
  --avg 3 \
  --epoch 10
```

## Notes

- Use checkpoint files from `checkpoint/` when running this recipe.
- ONNX deployment artifacts are maintained separately under `../deployment/models/`.
- Do not mix PyTorch checkpoints in this directory with ONNX files from different model releases unless the export path is explicitly verified.
