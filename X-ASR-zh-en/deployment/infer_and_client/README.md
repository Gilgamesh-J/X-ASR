# WebSocket Streaming ASR Server and Client

This directory contains the minimal WebSocket deployment path for X-ASR-zh-en with `sherpa-onnx`. It is intended for service-style streaming ASR, frontend integration, and reproducible local testing.

Run the commands below from the parent deployment directory:

```bash
cd X-ASR-zh-en/deployment
```

## Files

| File | Purpose |
| --- | --- |
| `sherpa_streaming_infer.py` | Wraps `sherpa_onnx.OnlineRecognizer`, handles streaming decode, text formatting, finalization, and optional silence-appending decode. |
| `sherpa_streaming_server.py` | Starts a WebSocket ASR server. Each WebSocket connection owns an independent recognizer session. |
| `sherpa_streaming_client.py` | Loads a WAV file, converts it to 16 kHz mono int16 PCM, streams chunks to the server, and prints partial/final results. |

## Update Log

This deployment entry now includes:

- Privacy-safe default model paths under `models/chunk-160ms-model/`.
- Optional interactive tail-probe mode in `sherpa_streaming_server.py`.
- `append_silence_and_decode()` in `sherpa_streaming_infer.py`, used by tail probing.
- A non-blocking async receive loop in `sherpa_streaming_client.py`, so the test client can keep receiving server messages while sending audio chunks.
- A final-result wait in the test client, which makes command-line verification easier.

## Server Modes

| Mode | How to enable | Use case |
| --- | --- | --- |
| Default streaming mode | `--enable-energy-tail-probe 0` | Conservative server behavior. The server decodes only from client-sent audio chunks. |
| Interactive tail-probe mode | `--enable-energy-tail-probe 1` | Voice-input demos where trailing partial results should refresh after the user pauses. |

Tail-probe mode watches input energy. After speech has been observed and the following low-energy segment lasts long enough, the server appends a short silence segment and decodes again. This is an interaction helper for streaming demos; it is not a replacement for a full VAD pipeline.

## Start the Server

Install dependencies first:

```bash
python -m venv .venv
source .venv/bin/activate
python -m pip install --upgrade pip
python -m pip install -r requirements.txt
```

Start the default 160 ms model on CPU:

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
  --num-threads 1 \
  --decoding-method greedy_search \
  --model-type zipformer2 \
  --enable-endpoint-detection 0 \
  --text-format none
```

Enable interactive tail-probe mode by adding the tail-probe options:

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
  --num-threads 1 \
  --decoding-method greedy_search \
  --model-type zipformer2 \
  --enable-endpoint-detection 0 \
  --text-format none \
  --enable-energy-tail-probe 1 \
  --low-energy-rms 0.003 \
  --speech-rms 0.010 \
  --min-speech-ms 200 \
  --min-silence-ms 500 \
  --tail-probe-ms 500 \
  --tail-probe-cooldown-ms 1000
```

The RMS thresholds should be tuned for microphone gain, background noise, and frontend chunk size.

## Test with the Client

Open another terminal in the same deployment directory:

```bash
source .venv/bin/activate

python infer_and_client/sherpa_streaming_client.py \
  --server-uri ws://127.0.0.1:6666 \
  --wav /path/to/test.wav \
  --chunk-ms 100 \
  --simulate-realtime 1
```

The client sends one PCM packet roughly every `--chunk-ms` milliseconds when `--simulate-realtime 1` is enabled. The server returns JSON messages such as:

```json
{"type": "partial", "text": "..."}
{"type": "final", "text": "..."}
```

## Client Options

| Option | Default | Description |
| --- | --- | --- |
| `--server-uri` | `ws://127.0.0.1:8766` | WebSocket server endpoint. |
| `--wav` | required | Local WAV/audio file used for testing. |
| `--chunk-ms` | `100` | Audio packet duration sent by the client. |
| `--simulate-realtime` | `1` | When enabled, sleep between packets to mimic real-time audio streaming. |

## Required Model Arguments

The following four files must come from the same model directory:

| Argument | Meaning |
| --- | --- |
| `--tokens` | Token table used by the exported model. |
| `--encoder` | Streaming encoder ONNX file. |
| `--decoder` | Transducer decoder ONNX file. |
| `--joiner` | Transducer joiner ONNX file. |

Do not mix `tokens.txt`, encoder, decoder, and joiner files from different chunk-size folders.

## Server Options

| Option | Default | Description |
| --- | --- | --- |
| `--host` | `0.0.0.0` | WebSocket listen host. |
| `--port` | `8766` | WebSocket listen port. |
| `--tokens` | `models/chunk-160ms-model/tokens.txt` | Token table path. |
| `--encoder` | `models/chunk-160ms-model/encoder-160ms.onnx` | Encoder ONNX path. |
| `--decoder` | `models/chunk-160ms-model/decoder-160ms.onnx` | Decoder ONNX path. |
| `--joiner` | `models/chunk-160ms-model/joiner-160ms.onnx` | Joiner ONNX path. |
| `--provider` | `cpu` | Inference backend, for example `cpu` or `cuda`. |
| `--sample-rate` | `16000` | Expected input audio sample rate. |
| `--feature-dim` | `80` | Fbank feature dimension. |
| `--num-threads` | `1` | CPU inference thread count. |
| `--decoding-method` | `greedy_search` | sherpa-onnx online decoding method. |
| `--model-type` | `zipformer2` | Model architecture type passed to sherpa-onnx. |
| `--enable-endpoint-detection` | `0` | Whether to enable sherpa-onnx endpoint detection. |
| `--text-format` | `lower` | Output formatting mode: `none`, `lower`, or `capitalize`. |
| `--enable-energy-tail-probe` | `0` | Enable optional energy-based tail probing. |
| `--low-energy-rms` | `0.003` | RMS threshold for low-energy audio. |
| `--speech-rms` | `0.010` | RMS threshold for speech activity. |
| `--min-speech-ms` | `200.0` | Minimum speech duration before tail probing can be armed. |
| `--min-silence-ms` | `500.0` | Required low-energy duration before tail probing triggers. |
| `--tail-probe-ms` | `500.0` | Silence duration appended before decoding again. |
| `--tail-probe-cooldown-ms` | `1000.0` | Cooldown between tail-probe triggers. |

## WebSocket Protocol

The minimal protocol is:

| Step | Message | Meaning |
| --- | --- | --- |
| 1 | JSON: `{"type": "start", "sample_rate": 16000}` | Start one recognition session. |
| 2 | Binary int16 PCM chunks | Stream audio to the recognizer. |
| 3 | JSON: `{"type": "end"}` | Finish the session and flush final output. |

Each WebSocket connection creates a separate recognizer stream. Requests from different clients do not share decoding state. For high concurrency, run multiple server processes and route clients with a load balancer or service gateway.

## Audio Format

The server expects 16 kHz mono signed int16 PCM bytes. The provided client accepts common WAV files and converts them to this format before sending.

For browser or microphone frontends, use the same audio contract: resample to 16 kHz, convert to mono int16 PCM, and send binary chunks at a stable interval.
