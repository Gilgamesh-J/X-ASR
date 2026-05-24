<h1 align="center">X-ASR Series</h1>

<p align="center">
  <b>Streaming-focused automatic speech recognition models based on icefall/k2, Zipformer, and sherpa-onnx.</b>
</p>

<p align="center">
  <a href="https://huggingface.co/GilgameshWind/icefall_X_ASR_streaming">Hugging Face</a> |
  <a href="https://stream-asr.sjtuxlance.com/">Online Demo</a> |
  <a href="X-ASR-zh-en/deployment/README.md">Deployment Guide</a>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/Current%20release-X--ASR--zh--en-blue" alt="Current release">
  <img src="https://img.shields.io/badge/Languages-zh%20%7C%20en-green" alt="Languages">
  <img src="https://img.shields.io/badge/Streaming-160ms%20%7C%20480ms%20%7C%20960ms%20%7C%201920ms-orange" alt="Streaming chunks">
  <img src="https://img.shields.io/badge/Runtime-sherpa--onnx-red" alt="Runtime">
  <img src="https://img.shields.io/badge/License-Apache--2.0-lightgrey" alt="License">
</p>

<p align="center">
  <a href="#overview">Overview</a> |
  <a href="#timeline">Timeline</a> |
  <a href="#model-releases">Model Releases</a> |
  <a href="#evaluation">Evaluation</a> |
  <a href="#quick-start">Quick Start</a> |
  <a href="#roadmap">Roadmap</a>
</p>

---

## Overview

X-ASR is a series of automatic speech recognition models based on the icefall framework, with a focus on streaming ASR and low-latency deployment while also supporting offline recognition.

This repository currently releases an initial batch of Chinese-English streaming ASR models. The X-ASR series will be continuously updated and scaled across languages, model architectures, and training data.

### X-ASR-zh-en

`X-ASR-zh-en` is trained on approximately 1 million hours of open-source and collected speech data. It is designed as an offline-streaming unified transducer ASR model, supporting both offline decoding and true streaming decoding.

The model supports multiple streaming chunk sizes, including 160 ms, 480 ms, 960 ms, and 1920 ms. It supports punctuation and casing, and can be deployed with sherpa-onnx.

<p align="center">
  <img src="https://huggingface.co/GilgameshWind/icefall_X_ASR_streaming/resolve/main/figure/zipformer.png" width="700" alt="Zipformer architecture">
</p>

## Timeline

> 2026-05 - Initial `X-ASR-zh-en` release with offline-streaming unified models and sherpa-onnx deployment artifacts.
> Coming soon - Streaming ASR releases for Thai, Indonesian, and Vietnamese.
> Ongoing - Scaling model size, improving architecture, refining training data, and improving punctuation/casing stability.

## Model Releases

| Model | Languages | Type | Streaming chunks | Deployment | Model files |
|---|---|---|---|---|---|
| `X-ASR-zh-en` | Chinese, English | Offline-streaming unified transducer ASR | 160 ms, 480 ms, 960 ms, 1920 ms | sherpa-onnx | [GitHub](X-ASR-zh-en/deployment), [Hugging Face](https://huggingface.co/GilgameshWind/icefall_X_ASR_streaming) |

## Highlights

| Category | Description |
|---|---|
| Framework | icefall / k2 |
| Architecture | Zipformer transducer |
| Training scale | Approximately 1 million hours of open-source and collected speech data |
| Current languages | Chinese and English |
| Decoding modes | Offline decoding and true streaming decoding |
| Streaming chunks | 160 ms, 480 ms, 960 ms, 1920 ms |
| Text output | Supports punctuation and casing |
| Runtime | sherpa-onnx |
| Interface | WebSocket streaming server and WAV-file client |

## Evaluation

The following results are for the current `X-ASR-zh-en` release. Values are WER/CER percentages; lower is better.

| Mode | Chunk size | Decoding method | LibriSpeech clean | LibriSpeech other | GigaSpeech | WenetSpeech test net | WenetSpeech test meeting |
|---|---:|---|---:|---:|---:|---:|---:|
| Offline | - | greedy search | 2.69 | 5.76 | 9.23 | 5.96 | 7.20 |
| Streaming | 160 ms | greedy search | 3.91 | 10.17 | 10.97 | 9.45 | 12.04 |
| Streaming | 480 ms | greedy search | 3.14 | 7.57 | 9.77 | 7.38 | 9.31 |
| Streaming | 960 ms | greedy search | 3.12 | 7.22 | 9.62 | 6.96 | 8.84 |
| Streaming | 1920 ms | greedy search | 2.84 | 6.47 | 9.46 | 6.42 | 8.03 |

## Demo

A sherpa-onnx based online demo is available here:

- [https://stream-asr.sjtuxlance.com/](https://stream-asr.sjtuxlance.com/)

Demo video:

<video controls width="70%" src="https://huggingface.co/GilgameshWind/icefall_X_ASR_streaming/resolve/main/demo/demo.mov"></video>

## Quick Start

### 1. Clone the repository

This repository uses Git LFS for ONNX model artifacts. Install Git LFS before cloning or before pulling model files.

```bash
git lfs install
git clone https://github.com/Gilgamesh-J/X-ASR-Series.git
cd X-ASR-Series
git lfs pull
```

Alternatively, download the model artifacts from Hugging Face:

```bash
hf download GilgameshWind/icefall_X_ASR_streaming \
  --local-dir ./X-ASR-zh-en/deployment
```

### 2. Install Python dependencies

```bash
cd X-ASR-zh-en/deployment
python -m venv .venv
source .venv/bin/activate
python -m pip install --upgrade pip
python -m pip install -r requirements.txt
```

### 3. Start the streaming server

The example below starts the 160 ms streaming model on CPU.

```bash
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

### 4. Test with a WAV file

Open another terminal:

```bash
cd X-ASR-zh-en/deployment
source .venv/bin/activate

python infer_and_client/sherpa_streaming_client.py \
  --server-uri ws://127.0.0.1:6666 \
  --wav /path/to/test.wav \
  --chunk-ms 100 \
  --simulate-realtime 1
```

The client sends 16 kHz mono int16 PCM chunks over WebSocket and prints partial and final results returned by the server.

For full deployment options, see [X-ASR-zh-en/deployment/README.md](X-ASR-zh-en/deployment/README.md).

## Repository Layout

```text
X-ASR-Series/
|-- README.md
|-- LICENSE
`-- X-ASR-zh-en/
    `-- deployment/
        |-- README.md
        |-- requirements.txt
        |-- infer_and_client/
        |   |-- sherpa_streaming_infer.py
        |   |-- sherpa_streaming_server.py
        |   `-- sherpa_streaming_client.py
        `-- models/
            |-- chunk-160ms-model/
            |-- chunk-480ms-model/
            |-- chunk-960ms-model/
            `-- chunk-1920ms-model/
```

## Model Variants

| Directory | Intended chunk size | Recommended use |
|---|---:|---|
| `X-ASR-zh-en/deployment/models/chunk-160ms-model` | 160 ms | Lowest latency, useful for real-time demos |
| `X-ASR-zh-en/deployment/models/chunk-480ms-model` | 480 ms | Low latency with slightly more context |
| `X-ASR-zh-en/deployment/models/chunk-960ms-model` | 960 ms | More stable output, higher latency |
| `X-ASR-zh-en/deployment/models/chunk-1920ms-model` | 1920 ms | Highest context among the provided models, highest latency |

## Roadmap

The X-ASR series will be continuously maintained and expanded in the following directions:

- **Languages**: We plan to release streaming ASR models for Thai, Indonesian, and Vietnamese in the short term. More languages will be added in future updates.
- **Model architecture**: We aim to continue scaling model sizes and exploring architecture improvements based on the k2/icefall ecosystem.
- **Training data**: We plan to refine part of the training data based on the current models and continue improving data quality and coverage.
- **Punctuation and casing**: We will improve the stability of punctuation and casing prediction in future releases.
- **Deployment**: We will keep improving sherpa-onnx based deployment examples and production usability.

## Contributing

We welcome feedback and contributions in the following areas:

- Deployment issues on different CPU/GPU environments
- Streaming latency and stability reports
- Evaluation results on new datasets or domains
- Requests for new languages or model variants
- Improvements to documentation and examples

Please open a GitHub issue with the environment, command, input audio format, and error log when reporting deployment problems.

## License

This project is released under the Apache-2.0 License.

## Acknowledgements

This model series is trained with icefall and deployed with sherpa-onnx.

- icefall: https://github.com/k2-fsa/icefall
- sherpa-onnx: https://github.com/k2-fsa/sherpa-onnx
