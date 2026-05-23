# X-ASR-Series
X-ASR is a series of automatic speech recognition models based on the icefall framework, focusing on streaming ASR and low-latency deployment.

## Overview

X-ASR is a series of automatic speech recognition models based on the icefall framework, focusing on streaming ASR while also supporting offline recognition.

This repository currently releases an initial batch of Chinese-English streaming ASR models. The X-ASR series will be continuously updated and scaled across languages, model architectures, and training data.

### X-ASR-zh-en

The currently released `X-ASR-zh-en` model is trained on approximately 1 million hours of open-source and collected speech data. It is designed as an offline-streaming unified transducer ASR model, supporting both offline decoding and true streaming decoding.

The model supports multiple streaming chunk sizes, including 160 ms, 480 ms, 960 ms, and 1920 ms. It also supports punctuation and casing, and can be conveniently deployed with sherpa-onnx.

<p align="center">
  <img src="TODO_FIGURE_URL" width="600">
</p>

## Roadmap

The X-ASR series will be continuously maintained and expanded in the following directions:

- **Languages**: In the short term, we plan to release streaming ASR models for Thai, Indonesian, and Vietnamese. More languages will be added in future updates.
- **Model architecture**: We aim to continue scaling model sizes and exploring architecture improvements based on the k2/icefall ecosystem.
- **Training data**: We plan to refine part of the training data based on the current models, and continue improving data quality and coverage.
- **Punctuation and casing**: We will improve the stability of punctuation and casing prediction in future releases.

## Highlights

### Model

- X-ASR series model
- Current release: `X-ASR-zh-en`
- Trained with icefall/k2 and Zipformer
- Trained on approximately 1 million hours of open-source and collected speech data

### Recognition

- Supports Chinese-English automatic speech recognition
- Supports both offline decoding and true streaming decoding
- Supports punctuation and casing
- Provides strong evaluation quality across multiple benchmarks

### Streaming

- Supports multiple streaming chunk sizes:
  - 160 ms
  - 480 ms
  - 960 ms
  - 1920 ms
- Designed for low-latency streaming recognition

### Deployment

- Exported and deployed with sherpa-onnx
- Provides a WebSocket-based streaming ASR server and client

## Model Evaluation

The following results are for the current `X-ASR-zh-en` release.

| Mode | Chunk size | Decoding method | LibriSpeech clean | LibriSpeech other | GigaSpeech | WenetSpeech test net | WenetSpeech test meeting |
|---|---:|---|---:|---:|---:|---:|---:|
| Offline | - | greedy search | 2.69 | 5.76 | 9.23 | 5.96 | 7.20 |
| Streaming | 160 ms | greedy search | 3.91 | 10.17 | 10.97 | 9.45 | 12.04 |
| Streaming | 480 ms | greedy search | 3.14 | 7.57 | 9.77 | 7.38 | 9.31 |
| Streaming | 960 ms | greedy search | 3.12 | 7.22 | 9.62 | 6.96 | 8.84 |
| Streaming | 1920 ms | greedy search | 2.84 | 6.47 | 9.46 | 6.42 | 8.03 |

## Demo

A demo based on sherpa-onnx is available here:

- Demo: TODO_DEMO_URL

Optional demo video:

```html
<video controls width="50%" src="TODO_DEMO_VIDEO_URL"></video>
```

## Pretrained Models

Pretrained models are hosted on Hugging Face.

| Model | Languages | Type | Hugging Face |
|---|---|---|---|
| X-ASR-zh-en | Chinese, English | Offline-streaming unified ASR | TODO_HF_MODEL_URL |

Download with Git:

```bash
git clone TODO_HF_MODEL_GIT_URL
```

Download with Hugging Face CLI:

```bash
hf download TODO_HF_REPO_ID
```

## Installation

### Requirements

Use Python 3.9 or newer.

```bash
python -m venv .venv
source .venv/bin/activate

python -m pip install --upgrade pip
python -m pip install numpy websockets soundfile librosa sherpa-onnx
```

### Install from Source

```bash
git clone TODO_GITHUB_REPO_URL
cd TODO_REPO_NAME

python -m pip install -r requirements.txt
```

## Quick Start

### Start the Streaming Server

Run the server with the 160 ms model:

```bash
cd deployment
source .venv/bin/activate

python infer_and_client/sherpa_streaming_server.py \
  --host 0.0.0.0 \
  --port 6666 \
  --tokens models/chunk-160ms-model/tokens.txt \
  --encoder models/chunk-160ms-model/encoder-160ms.onnx \
  --decoder models/chunk-160ms-model/decoder-160ms.onnx \
  --joiner models/chunk-160ms-model/joiner-160ms.onnx \
  --provider cpu \
  --sample-rate 16000 \
  --feature-dim 80 \
  --decoding-method greedy_search \
  --model-type zipformer2 \
  --text-format none
```

### Test with a WAV File

In another terminal:

```bash
cd deployment
source .venv/bin/activate

python infer_and_client/sherpa_streaming_client.py \
  --server-uri ws://127.0.0.1:6666 \
  --wav /path/to/test.wav \
  --chunk-ms 100 \
  --simulate-realtime 1
```

The client sends 16 kHz mono int16 PCM chunks over WebSocket and prints partial and final results returned by the server.

## Directory Layout

```text
deployment/
├── infer_and_client/
│   ├── sherpa_streaming_infer.py    # sherpa-onnx wrapper and text formatting
│   ├── sherpa_streaming_server.py   # WebSocket streaming ASR server
│   └── sherpa_streaming_client.py   # WAV-file WebSocket test client
└── models/
    ├── chunk-160ms-model/
    │   ├── encoder-160ms.onnx
    │   ├── decoder-160ms.onnx
    │   ├── joiner-160ms.onnx
    │   └── tokens.txt
    ├── chunk-480ms-model/
    ├── chunk-960ms-model/
    └── chunk-1920ms-model/
```

## Model Variants

| Directory | Encoder | Decoder | Joiner | Tokens | Intended chunk size |
|---|---|---|---|---|---:|
| `models/chunk-160ms-model` | `encoder-160ms.onnx` | `decoder-160ms.onnx` | `joiner-160ms.onnx` | `tokens.txt` | 160 ms |
| `models/chunk-480ms-model` | `encoder-480ms.onnx` | `decoder-480ms.onnx` | `joiner-480ms.onnx` | `tokens.txt` | 480 ms |
| `models/chunk-960ms-model` | `encoder-960ms.onnx` | `decoder-960ms.onnx` | `joiner-960ms.onnx` | `tokens.txt` | 960 ms |
| `models/chunk-1920ms-model` | `encoder-1920ms.onnx` | `decoder-1920ms.onnx` | `joiner-1920ms.onnx` | `tokens.txt` | 1920 ms |

Smaller chunks usually produce lower latency. Larger chunks may be more stable depending on the acoustic condition and speaking style.

## Deployment with sherpa-onnx

This deployment uses `sherpa-onnx` as the online inference runtime. The exported Zipformer transducer model is loaded by:

```python
sherpa_onnx.OnlineRecognizer.from_transducer(...)
```

The server wraps this recognizer with a WebSocket interface. A client sends streaming PCM audio chunks, and the server returns partial and final recognition results.

### Deployment Steps

1. Choose one model directory under `models/`.
2. Install Python dependencies and `sherpa-onnx`.
3. Start `sherpa_streaming_server.py` with the matching `tokens`, `encoder`, `decoder`, and `joiner`.
4. Send audio through WebSocket from either `sherpa_streaming_client.py` or your own frontend.

### Required Model Arguments

These four files must come from the same model directory:

| Argument | Meaning |
|---|---|
| `--tokens` | Token table used by the exported model |
| `--encoder` | Streaming encoder ONNX file |
| `--decoder` | Transducer decoder ONNX file |
| `--joiner` | Transducer joiner ONNX file |

Do not mix `tokens.txt`, encoder, decoder, and joiner files from different model folders.

### Runtime Options

| Option | Typical value | Description |
|---|---|---|
| `--provider` | `cpu` or `cuda` | Inference backend used by sherpa-onnx |
| `--num-threads` | `1`, `2`, or `4` | CPU thread count |
| `--sample-rate` | `16000` | Input audio sample rate expected by the recognizer |
| `--feature-dim` | `80` | Log-Mel/Fbank feature dimension |
| `--model-type` | `zipformer2` | Model architecture type passed to sherpa-onnx |
| `--decoding-method` | `greedy_search` | Online decoding method |
| `--enable-endpoint-detection` | `0` | Whether sherpa-onnx endpoint detection is enabled |
| `--text-format` | `none`, `lower`, or `capitalize` | Post-processing mode applied after decoding |

For CPU deployment, start with:

```bash
--provider cpu --num-threads 1
```

For CUDA deployment, use:

```bash
--provider cuda
```

CUDA only works if your installed `sherpa-onnx` package was built with CUDA support.

### Choosing a Chunk Size

| Model | Recommended use |
|---|---|
| `chunk-160ms-model` | Lowest latency, useful for real-time demos |
| `chunk-480ms-model` | Low latency with slightly more context |
| `chunk-960ms-model` | More stable output, higher latency |
| `chunk-1920ms-model` | Highest context among the provided models, highest latency |

The actual perceived latency also depends on how frequently the client sends audio chunks. The included test client uses:

```bash
--chunk-ms 100
```

This means the client sends one audio packet roughly every 100 ms when `--simulate-realtime 1` is enabled.

### Text Formatting Choices

Use `--text-format none` if you want the raw model casing as much as possible:

```bash
--text-format none
```

Use `--text-format lower` if you want English output lowercased:

```bash
--text-format lower
```

Use `--text-format capitalize` for a simple first-letter capitalization pass:

```bash
--text-format capitalize
```

All modes still apply spacing normalization for Chinese text and punctuation.

### Production Deployment Notes

For a simple persistent deployment, run the server in `tmux`, `systemd`, Docker, or any process supervisor.

The server itself does not implement an instance pool. If you need higher concurrency, run multiple server processes on different ports and put a load balancer or routing layer in front of them.

## Offline Recognition

TODO: Add offline decoding instructions.

```bash
# TODO
```

## Streaming Recognition with icefall

TODO: Add icefall streaming decoding instructions.

```bash
# TODO
```

## Training

TODO: Add training data description, recipe path, and training command.

### Data

TODO

### Recipe

TODO

### Training Command

```bash
# TODO
```

## Export

TODO: Add ONNX export instructions.

### Export to ONNX

```bash
# TODO
```

### Export for sherpa-onnx

```bash
# TODO
```

## Evaluation Reproduction

TODO: Add instructions for reproducing benchmark results.

```bash
# TODO
```

## Citation

TODO

```bibtex
@misc{xasr,
  title = {X-ASR},
  author = {},
  year = {},
  url = {}
}
```

## License

This project is released under the Apache-2.0 License.

TODO: Add details about model/data license constraints if needed.

## Acknowledgements

This model series is trained with icefall and deployed with sherpa-onnx.

- icefall: https://github.com/k2-fsa/icefall
- sherpa-onnx: https://github.com/k2-fsa/sherpa-onnx
