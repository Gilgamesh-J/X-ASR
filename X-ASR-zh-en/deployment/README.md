# Streaming Zipformer ASR ONNX Deployment

This folder contains deployment-ready ONNX models and a minimal WebSocket server/client for streaming ASR inference with `sherpa-onnx`.

The package is intended for users who want to run the exported streaming Zipformer models locally or on a server. It does not require the original training code.

## Directory Layout

```text
X-ASR-zh-en/deployment/
├── requirements.txt                 # Python dependencies
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

Each model directory contains one streaming transducer model exported as four files:

- `encoder-*.onnx`
- `decoder-*.onnx`
- `joiner-*.onnx`
- `tokens.txt`

## Model Variants

| Directory | Encoder | Decoder | Joiner | Tokens | Intended chunk size |
| --- | --- | --- | --- | --- | --- |
| `models/chunk-160ms-model` | `encoder-160ms.onnx` | `decoder-160ms.onnx` | `joiner-160ms.onnx` | `tokens.txt` | 160 ms |
| `models/chunk-480ms-model` | `encoder-480ms.onnx` | `decoder-480ms.onnx` | `joiner-480ms.onnx` | `tokens.txt` | 480 ms |
| `models/chunk-960ms-model` | `encoder-960ms.onnx` | `decoder-960ms.onnx` | `joiner-960ms.onnx` | `tokens.txt` | 960 ms |
| `models/chunk-1920ms-model` | `encoder-1920ms.onnx` | `decoder-1920ms.onnx` | `joiner-1920ms.onnx` | `tokens.txt` | 1920 ms |

Smaller chunks usually produce lower latency. Larger chunks may be more stable depending on the acoustic condition and speaking style.

## Requirements

### Supported Environment

| Item | Requirement |
| --- | --- |
| OS | Linux is recommended for server deployment. macOS also works for local testing. Windows users should use WSL2 if possible. |
| Python | Python 3.9 or newer. Python 3.10/3.11 are recommended for server deployment. |
| Architecture | x86_64 or arm64. |
| CPU | 4 CPU cores or more are recommended for smooth CPU inference. |
| Memory | At least 4 GB RAM for one server process. Use more memory if you run several models or several processes. |
| Disk | Each model directory is about 586 MB. The full `models/` directory is about 2.4 GB. Reserve extra space for the Python environment. |
| Audio input | 16 kHz mono signed int16 PCM is expected by the WebSocket server. |
| Network | One open TCP port is required for the WebSocket server, for example `8766`. |
| GPU | Optional. CUDA inference requires a CUDA-enabled `sherpa-onnx` build and a compatible NVIDIA driver/CUDA runtime. |

### System Packages

On Ubuntu/Debian:

```bash
sudo apt-get update
sudo apt-get install -y \
  python3 \
  python3-venv \
  python3-pip \
  libsndfile1 \
  ffmpeg \
  tmux
```

On macOS with Homebrew:

```bash
brew install python libsndfile ffmpeg tmux
```

Notes:

- `libsndfile` is used by `soundfile` for reading WAV/audio files in the test client.
- `ffmpeg` is not required for raw WebSocket inference, but it is useful when preparing or converting audio files.
- `tmux` is optional, but useful for keeping the WebSocket server running in the background.

### Python Packages

The Python dependencies are listed in `requirements.txt`:

```text
numpy
websockets
soundfile
librosa
sherpa-onnx
```

Package roles:

| Package | Used by | Purpose |
| --- | --- | --- |
| `sherpa-onnx` | Server | Loads the ONNX encoder/decoder/joiner and performs streaming ASR inference. |
| `numpy` | Server and client | Converts PCM bytes and waveform arrays. |
| `websockets` | Server and client | Implements the WebSocket transport. |
| `soundfile` | Client | Loads WAV/audio files for testing. |
| `librosa` | Client | Resamples test audio to 16 kHz when needed. |

Install them with:

```bash
python -m venv .venv
source .venv/bin/activate
python -m pip install --upgrade pip
python -m pip install -r requirements.txt
```

If you do not use the WAV-file client and only run the WebSocket server, the minimal server dependencies are:

```bash
python -m pip install numpy websockets sherpa-onnx
```

### CPU Deployment Environment

CPU deployment is the simplest setup. Use the standard `sherpa-onnx` Python package and start the server with:

```bash
--provider cpu
```

For CPU inference, `--num-threads` controls the number of CPU threads used by the recognizer:

```bash
--provider cpu --num-threads 1
```

Increase `--num-threads` only after measuring throughput and latency. More threads do not always reduce latency for a single streaming session.

### CUDA Deployment Environment

CUDA deployment requires:

- NVIDIA GPU
- Compatible NVIDIA driver
- CUDA runtime compatible with your `sherpa-onnx` build
- A CUDA-enabled `sherpa-onnx` package

Start the server with:

```bash
--provider cuda
```

If CUDA is unavailable or the installed `sherpa-onnx` package does not support CUDA, use CPU mode:

```bash
--provider cpu
```

### Input Audio Requirements

The WebSocket server expects binary audio chunks in this format:

| Field | Value |
| --- | --- |
| Sample rate | 16,000 Hz |
| Channels | 1 channel, mono |
| Sample format | signed int16 PCM |
| Byte order | little-endian |

The included client automatically loads an audio file, converts it to mono, resamples it to 16 kHz if needed, converts it to int16 PCM, and sends it to the server in chunks.

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

Example:

```bash
python infer_and_client/sherpa_streaming_server.py \
  --host 0.0.0.0 \
  --port 8766 \
  --tokens models/chunk-160ms-model/tokens.txt \
  --encoder models/chunk-160ms-model/encoder-160ms.onnx \
  --decoder models/chunk-160ms-model/decoder-160ms.onnx \
  --joiner models/chunk-160ms-model/joiner-160ms.onnx \
  --provider cpu \
  --sample-rate 16000 \
  --feature-dim 80 \
  --num-threads 1 \
  --decoding-method greedy_search \
  --model-type zipformer2 \
  --enable-endpoint-detection 0 \
  --text-format none
```

### Required Model Arguments

These four files must come from the same model directory:

| Argument | Meaning |
| --- | --- |
| `--tokens` | Token table used by the exported model |
| `--encoder` | Streaming encoder ONNX file |
| `--decoder` | Transducer decoder ONNX file |
| `--joiner` | Transducer joiner ONNX file |

Do not mix `tokens.txt`, encoder, decoder, and joiner files from different model folders.

### Runtime Options

| Option | Typical value | Description |
| --- | --- | --- |
| `--provider` | `cpu` or `cuda` | Inference backend used by sherpa-onnx |
| `--num-threads` | `1`, `2`, or `4` | CPU thread count. This mainly affects CPU inference |
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
| --- | --- |
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

Each WebSocket connection creates one streaming ASR session. Long-running sessions keep their own recognizer stream state until the client sends `end`, sends `reset`, or disconnects.

## Quick Start

Run the server with the 160 ms model:

```bash
cd X-ASR-zh-en/deployment
source .venv/bin/activate

python infer_and_client/sherpa_streaming_server.py \
  --host 0.0.0.0 \
  --port 8766 \
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

In another terminal, test it with a WAV file:

```bash
cd X-ASR-zh-en/deployment
source .venv/bin/activate

python infer_and_client/sherpa_streaming_client.py \
  --server-uri ws://127.0.0.1:8766 \
  --wav /path/to/test.wav \
  --chunk-ms 100 \
  --simulate-realtime 1
```

The client sends 16 kHz mono int16 PCM chunks over WebSocket and prints partial/final results returned by the server.

## Running Other Model Variants

480 ms:

```bash
python infer_and_client/sherpa_streaming_server.py \
  --port 8766 \
  --tokens models/chunk-480ms-model/tokens.txt \
  --encoder models/chunk-480ms-model/encoder-480ms.onnx \
  --decoder models/chunk-480ms-model/decoder-480ms.onnx \
  --joiner models/chunk-480ms-model/joiner-480ms.onnx \
  --provider cpu \
  --text-format none
```

960 ms:

```bash
python infer_and_client/sherpa_streaming_server.py \
  --port 8766 \
  --tokens models/chunk-960ms-model/tokens.txt \
  --encoder models/chunk-960ms-model/encoder-960ms.onnx \
  --decoder models/chunk-960ms-model/decoder-960ms.onnx \
  --joiner models/chunk-960ms-model/joiner-960ms.onnx \
  --provider cpu \
  --text-format none
```

1920 ms:

```bash
python infer_and_client/sherpa_streaming_server.py \
  --port 8766 \
  --tokens models/chunk-1920ms-model/tokens.txt \
  --encoder models/chunk-1920ms-model/encoder-1920ms.onnx \
  --decoder models/chunk-1920ms-model/decoder-1920ms.onnx \
  --joiner models/chunk-1920ms-model/joiner-1920ms.onnx \
  --provider cpu \
  --text-format none
```

## WebSocket Protocol

The server accepts one WebSocket connection per recognition session.

### Start a Session

Send a JSON text message:

```json
{"type": "start", "sample_rate": 16000}
```

The server replies:

```json
{"type": "started", "sample_rate": 16000}
```

### Send Audio

Send binary messages containing raw PCM audio:

- format: signed int16 little-endian
- sample rate: 16 kHz recommended
- channel: mono

For example, 100 ms of audio at 16 kHz contains `1600` samples, or `3200` bytes.

After each audio chunk, the server decodes all currently available frames and returns:

```json
{"type": "partial", "text": "..."}
```

### Finish a Session

Send:

```json
{"type": "end"}
```

The server calls `input_finished()` on the sherpa-onnx stream, drains the remaining frames, and returns:

```json
{
  "type": "final",
  "text": "...",
  "first_partial_latency": 0.42
}
```

`first_partial_latency` is measured in seconds from the first accepted audio samples to the first non-empty partial result.

### Reset a Session

Send:

```json
{"type": "reset"}
```

The server creates a new recognizer stream and replies:

```json
{"type": "reset_ok"}
```

### Ping

Send:

```json
{"type": "ping"}
```

The server replies:

```json
{"type": "pong"}
```

## Text Formatting

The server exposes:

```bash
--text-format none
--text-format lower
--text-format capitalize
```

Formatting is implemented in `infer_and_client/sherpa_streaming_infer.py`.

The current normalization also removes unnecessary spaces:

- between Chinese characters
- between Chinese text and Chinese punctuation
- before common English punctuation such as `, . ! ? ; : %`

Use `--text-format none` if you want to preserve model casing as much as possible.

## Server Options

Common options from `sherpa_streaming_server.py`:

| Option | Default | Description |
| --- | --- | --- |
| `--host` | `0.0.0.0` | WebSocket listen host |
| `--port` | `8766` | WebSocket listen port |
| `--tokens` | required in practice | Path to `tokens.txt` |
| `--encoder` | required in practice | Path to encoder ONNX |
| `--decoder` | required in practice | Path to decoder ONNX |
| `--joiner` | required in practice | Path to joiner ONNX |
| `--provider` | `cpu` | `cpu`, `cuda`, or another provider supported by your sherpa-onnx build |
| `--sample-rate` | `16000` | Expected sample rate |
| `--feature-dim` | `80` | Fbank feature dimension |
| `--num-threads` | `1` | CPU inference thread count |
| `--decoding-method` | `greedy_search` | sherpa-onnx online decoding method |
| `--model-type` | `zipformer2` | Model type passed to sherpa-onnx |
| `--enable-endpoint-detection` | `0` | Whether to enable endpoint detection |
| `--text-format` | `lower` | Output formatting mode |

## Running as a Background Service

For a simple server deployment, use `tmux`:

```bash
tmux new-session -d -s streaming-asr \
  'cd /path/to/X-ASR-Series/X-ASR-zh-en/deployment && source .venv/bin/activate && python infer_and_client/sherpa_streaming_server.py \
    --host 0.0.0.0 \
    --port 8766 \
    --tokens models/chunk-160ms-model/tokens.txt \
    --encoder models/chunk-160ms-model/encoder-160ms.onnx \
    --decoder models/chunk-160ms-model/decoder-160ms.onnx \
    --joiner models/chunk-160ms-model/joiner-160ms.onnx \
    --provider cpu \
    --text-format none'
```

Check logs:

```bash
tmux attach -t streaming-asr
```

Detach without stopping the service:

```text
Ctrl-b d
```

Stop the service:

```bash
tmux kill-session -t streaming-asr
```

## Integrating With a Frontend

The frontend should:

1. Open a WebSocket connection to the server.
2. Send `{"type": "start", "sample_rate": 16000}`.
3. Capture microphone audio.
4. Convert audio to 16 kHz mono int16 PCM.
5. Send PCM chunks as binary WebSocket messages.
6. Render `partial` messages live.
7. Send `{"type": "end"}` when the user stops recording.
8. Render the returned `final` message.

The server does not perform browser microphone capture. It only receives audio bytes over WebSocket.

## Troubleshooting

### `ModuleNotFoundError: No module named 'sherpa_onnx'`

Install `sherpa-onnx` in the active Python environment:

```bash
python -m pip install sherpa-onnx
```

### No text is produced

Check the following:

- The client sent `{"type": "start"}` before audio bytes.
- Audio is signed int16 PCM, not float32 bytes.
- Audio sample rate is 16 kHz or is resampled before sending.
- `tokens.txt`, encoder, decoder, and joiner paths all come from the same model directory.

### Output casing is changed

Use:

```bash
--text-format none
```

The default server argument is `lower`, which lowercases English text.

### CUDA does not work

Check that your `sherpa-onnx` installation supports CUDA and that the CUDA runtime is available. If not, use:

```bash
--provider cpu
```

## Notes for Publishing on Hugging Face

Before uploading this folder to Hugging Face:

- Remove local system files such as `.DS_Store`.
- Add a `LICENSE` file.
- Add model training/evaluation details if you want the repository to serve as a full model card.
- Keep the relative directory layout unchanged so that the commands in this README remain valid.
