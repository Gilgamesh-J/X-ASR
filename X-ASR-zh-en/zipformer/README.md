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
`-- checkpoint/
    |-- pretrained.pt
    `-- fintuned_with_punctuation.pt
```

## Checkpoints

| File | Description |
| --- | --- |
| `checkpoint/pretrained.pt` | The base checkpoint obtained from the main X-ASR-zh-en training run. |
| `checkpoint/fintuned_with_punctuation.pt` | A checkpoint fine-tuned from `checkpoint/pretrained.pt` to improve punctuation prediction and true English casing. |

## Training

The full training command will be added after the release command line is finalized.

```bash
# TODO: add the X-ASR-zh-en Zipformer training command here.
```

## Decoding

The decoding command will be added after the release command line is finalized.

```bash
# TODO: add the X-ASR-zh-en Zipformer decoding command here.
```

## Notes

- Use checkpoint files from `checkpoint/` when running this recipe.
- ONNX deployment artifacts are maintained separately under `../deployment/models/`.
- Do not mix PyTorch checkpoints in this directory with ONNX files from different model releases unless the export path is explicitly verified.
