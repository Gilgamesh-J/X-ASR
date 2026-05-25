<h1 align="center">🎙️ X-ASR Series</h1>

<p align="center">
  <b>Streaming-focused automatic speech recognition models based on icefall/k2, Zipformer, and sherpa-onnx.</b>
</p>

<p align="center">
  <sub>
    🏛️ Shanghai Jiao Tong University &nbsp;·&nbsp; Fudan University &nbsp;·&nbsp; Shanghai Innovation Institute &nbsp;·&nbsp; Huazhong University of Science and Technology
  </sub>
</p>

<p align="center">
  <b>🌐 <a href="README_zh.md">中文版</a></b>
</p>

<p align="center">
  <a href="https://huggingface.co/GilgameshWind/icefall_X_ASR_streaming">🤗 Hugging Face</a> |
  <a href="https://stream-asr.sjtuxlance.com/">🎧 Online Demo</a> |
  <a href="X-ASR-zh-en/deployment/README.md">🚀 Deployment Guide</a>
</p>

<p align="center">
  <b>📄 X-ASR-zh-en Technical Report: Coming Soon</b>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/Current%20release-X--ASR--zh--en-blue" alt="Current release">
  <img src="https://img.shields.io/badge/Languages-zh%20%7C%20en-green" alt="Languages">
  <img src="https://img.shields.io/badge/Streaming-160ms%20%7C%20480ms%20%7C%20960ms%20%7C%201920ms-orange" alt="Streaming chunks">
  <img src="https://img.shields.io/badge/Runtime-sherpa--onnx-red" alt="Runtime">
  <img src="https://img.shields.io/badge/Report-coming%20soon-purple" alt="Report status">
  <img src="https://img.shields.io/badge/License-Apache--2.0-lightgrey" alt="License">
</p>

<p align="center">
  <a href="#overview">🔍 Overview</a> |
  <a href="#timeline">📅 Timeline</a> |
  <a href="#model-releases">📦 Model Releases</a> |
  <a href="#evaluation">📊 Evaluation</a> |
  <a href="#quick-start">🚀 Quick Start</a>
</p>

---

<a id="overview"></a>

## 🔍 Overview

**X-ASR** is a series of automatic speech recognition models built with the **icefall** framework. The series focuses on **streaming ASR** and **low-latency deployment**, while also supporting offline recognition. This repository currently releases an initial batch of **Chinese-English streaming ASR models**, and the X-ASR series will be continuously maintained, updated, and scaled across **languages**, **model architectures**, and **training data**.

### X-ASR-zh-en

**X-ASR-zh-en** is trained on approximately **1 million hours** of open-source and collected speech data. It is designed as an **offline-streaming unified transducer ASR model** with the **Zipformer architecture**, supporting both **offline decoding** and **true streaming decoding**. The model provides multiple streaming chunk sizes: **160 ms**, **480 ms**, **960 ms**, and **1920 ms**, supports **punctuation and casing**, and can be conveniently deployed with **sherpa-onnx**.

<p align="center">
  <img src="assets/figures/zipformer.png" width="700" alt="Zipformer architecture">
</p>

<a id="timeline"></a>

## 📅 Timeline

| Time | Update |
|---|---|
| 2026-05 | Initial `X-ASR-zh-en` release with offline-streaming unified models and sherpa-onnx deployment artifacts. |
| Coming Soon | `X-ASR-zh-en` technical report with training, evaluation, and deployment details. |
| Coming Soon | Streaming ASR releases for Thai, Indonesian, and Vietnamese. |
| Ongoing | Model scaling, architecture improvements, data refinement, and more stable punctuation/casing. |

<a id="model-releases"></a>

## 📦 Model Releases

| Model | Languages | Type | Streaming chunks | Deployment | Report | Model files |
|---|---|---|---|---|---|---|
| `X-ASR-zh-en` | Chinese, English | Offline-streaming unified transducer ASR | 160 ms, 480 ms, 960 ms, 1920 ms | sherpa-onnx | **Coming Soon** | [GitHub](X-ASR-zh-en/deployment), [Hugging Face](https://huggingface.co/GilgameshWind/icefall_X_ASR_streaming) |

## ⭐ Highlights

| Category | Description |
|---|---|
| **Framework** | icefall / k2 |
| **Architecture** | Zipformer transducer |
| **Training scale** | Approximately 1 million hours of open-source and collected speech data |
| **Current languages** | Chinese and English |
| **Decoding modes** | Offline decoding and true streaming decoding |
| **Streaming chunks** | 160 ms, 480 ms, 960 ms, 1920 ms |
| **Text output** | Supports punctuation and casing |
| **Runtime** | sherpa-onnx |
| **Interface** | WebSocket streaming server and WAV-file client |

<a id="evaluation"></a>

## 📊 Evaluation

The following results are for the current **X-ASR-zh-en** release. Values are **WER/CER percentages**; lower is better. All results are reported with **greedy search**.

<table>
  <thead>
    <tr>
      <th rowspan="2">Mode</th>
      <th rowspan="2">Chunk size</th>
      <th colspan="2">LibriSpeech</th>
      <th rowspan="2">GigaSpeech</th>
      <th colspan="2">WenetSpeech</th>
    </tr>
    <tr>
      <th>clean</th>
      <th>other</th>
      <th>net</th>
      <th>meeting</th>
    </tr>
  </thead>
  <tbody>
    <tr>
      <td>Streaming</td>
      <td>160 ms</td>
      <td>3.91</td>
      <td>10.17</td>
      <td>10.97</td>
      <td>9.45</td>
      <td>12.04</td>
    </tr>
    <tr>
      <td>Streaming</td>
      <td>480 ms</td>
      <td>3.14</td>
      <td>7.57</td>
      <td>9.77</td>
      <td>7.38</td>
      <td>9.31</td>
    </tr>
    <tr>
      <td>Streaming</td>
      <td>960 ms</td>
      <td>3.12</td>
      <td>7.22</td>
      <td>9.62</td>
      <td>6.96</td>
      <td>8.84</td>
    </tr>
    <tr>
      <td>Streaming</td>
      <td>1920 ms</td>
      <td>2.84</td>
      <td>6.47</td>
      <td>9.46</td>
      <td>6.42</td>
      <td>8.03</td>
    </tr>
    <tr>
      <td>Offline</td>
      <td>-</td>
      <td><b>2.69</b></td>
      <td><b>5.76</b></td>
      <td><b>9.23</b></td>
      <td><b>5.96</b></td>
      <td><b>7.20</b></td>
    </tr>
  </tbody>
</table>

**Note:** Bold numbers indicate the best result among the listed modes for each benchmark column.

## 🎧 Demo

A **sherpa-onnx based online demo** is available here:

- [https://stream-asr.sjtuxlance.com/](https://stream-asr.sjtuxlance.com/)

Demo video:

<a href="assets/demos/demo.mov">
  <img src="assets/figures/demo-preview.png" width="700" alt="X-ASR demo video preview">
</a>

[Open demo video](assets/demos/demo.mov)

<a id="quick-start"></a>

## 🚀 Quick Start

### 1. Clone the repository

This repository uses **Git LFS** for ONNX model artifacts and demo media. Install Git LFS before cloning or before pulling large files.

```bash
git lfs install
git clone https://github.com/Gilgamesh-J/X-ASR.git
cd X-ASR
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

The example below starts the **160 ms streaming model** on CPU.

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

The client sends **16 kHz mono int16 PCM chunks** over WebSocket and prints partial and final results returned by the server.

For full deployment options, see [X-ASR-zh-en/deployment/README.md](X-ASR-zh-en/deployment/README.md).

## 🗂️ Repository Layout

```text
X-ASR/
|-- README.md
|-- README_zh.md
|-- LICENSE
|-- assets/
|   |-- figures/
|   |   |-- demo-preview.png
|   |   `-- zipformer.png
|   `-- demos/
|       `-- demo.mov
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

## 🤝 Contributing

We welcome feedback and contributions in the following areas:

- Deployment issues on different CPU/GPU environments
- Streaming latency and stability reports
- Evaluation results on new datasets or domains
- Requests for new languages or future releases
- Improvements to documentation and examples

When reporting deployment problems, please include the **environment**, **command**, **input audio format**, and **error log**.

## 📜 License

This project is released under the **Apache-2.0 License**.

## 🙏 Acknowledgements

This model series is trained with **icefall** and deployed with **sherpa-onnx**.

- icefall: https://github.com/k2-fsa/icefall
- sherpa-onnx: https://github.com/k2-fsa/sherpa-onnx
