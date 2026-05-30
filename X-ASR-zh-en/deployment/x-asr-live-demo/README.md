# X-ASR Live Demo

English | [中文](./README_zh.md)

![Streaming voice input demo](./assets/streaming-demo.gif)

> Chinese-English code-switch streams in place — partials refresh live with a moving cursor, a pause commits the line.

A **ready-to-run, local, end-to-end streaming ASR demo**: microphone/wav → **VAD segmentation** → X-ASR streaming zipformer decoding word-by-word → prints partial / final + latency.

X-ASR's streaming ASR is strong, but the decoder itself **does no endpointing** — it can't tell where an utterance ends. This demo adds a **VAD gate + sentence endpointing** in front of it, with **3 pluggable VAD backends**. No server needed: plug in a mic and experience the full low-latency pipeline in 30 seconds.

> Complements the existing `deployment/` (WebSocket server/client): that is server-side streaming; this is the **local, server-less, auto-segmenting** minimal loop — also handy for shaking out model/latency issues.

## Motivation

**VAD (endpointing) + streaming ASR** together are the foundation of a **fully local, offline, privacy-preserving** voice-input stack.

This example exists to make that concrete: with this pipeline you can **quickly build a purely local voice input method / live dictation** — speak and text appears, auto-segmented and committed, with no network, no cloud API, and data never leaving the device.

All the key pieces are already here: the VAD decides when a sentence starts/ends, the streaming zipformer emits text as you speak, preroll recovers the sentence start, and the falling-edge endpoint commits the line. Swap the `[final]` callback from "print" to "inject into the focused text field / IME" and you have a working local voice-IME prototype.

## Streaming feel

The whole point is that **text appears as you speak**: the partial refreshes token-by-token *in place*, the cursor `▌` rides the latest character, and a brief pause commits the line as `[final]`. Code-switching (中文 + English) streams through seamlessly:

```text
spoken:  “这个 streaming demo 真的很 smooth，中英混说也能 real-time 出字。”

t+0.3s   [partial] 这个▌
t+0.8s   [partial] 这个 streaming demo▌
t+1.5s   [partial] 这个 streaming demo 真的很 smooth▌
t+2.2s   [partial] 这个 streaming demo 真的很 smooth，中英混说也能▌
         ── pause detected → commit ──
t+2.6s   [final  ] 这个 streaming demo 真的很 smooth，中英混说也能 real-time 出字。   (finalize 38ms, seg 2.4s, RTF 0.02)
```

The line refreshes in place (`\r` + single-line, CJK-width-aware truncation) with the cursor `▌` pinned to the newest character — no wrapping, no scroll spam. Wire that `[final]` into a focused text field and it *is* a voice input method that types as you talk.

## Features

- **Three pluggable VADs**, one `run()` loop, swapped by duck typing:
  - `firered` (**default**) — [FireRedVAD](https://github.com/FireRedTeam/FireRedVAD) (DFSMN streaming, 0.6M params, 97.57% frame-F1 on FLEURS-VAD-102, reported to beat Silero/TEN/FunASR/WebRTC, Apache-2.0). **Auto-falls back to silero** when not installed or weights are missing, so the demo never breaks.
  - `silero` — sherpa-onnx's built-in silero VAD; only needs `sherpa-onnx`; robust.
  - `energy` — a teaching-grade pure-Python energy gate; **zero models, zero extra deps**; the code *is* the principle.
- **Reliable sentence endpointing**: finalizes on the VAD's speech→silence falling edge (`is_speech_detected()`), rather than the segment queue that is unreliable on a live stream — **multiple consecutive sentences never get stuck**.
- **Onset preroll**: re-feeds the audio the VAD's onset latency would otherwise drop, so sentence beginnings aren't clipped (`--preroll`).
- **Clean single-line refresh**: partials are truncated to terminal width (CJK counted as 2 columns) — long sentences don't spam the screen and adapt to window size.
- **CJK de-spacing normalization** + punctuation (reused from X-ASR deployment).
- Live microphone (M1) / wav file (M0); CPU or CoreML provider.

## Install

```bash
# Core (silero / energy work out of the box)
pip install -r requirements.txt

# Optional: enable the default FireRedVAD
pip install -r requirements-firered.txt

# Download weights: ASR (X-ASR-zh-en chunk-960ms) + silero + (optional) FireRedVAD
./download_models.sh
```

Resulting layout:
```
models/asr/{encoder,decoder,joiner}-960ms.onnx + tokens.txt   # X-ASR streaming zipformer
models/silero_vad.onnx                                        # silero backend
models/firered_vad/{model.pth.tar,cmvn.ark}                   # FireRedVAD (optional)
```

## Usage

```bash
# recommended: default FireRedVAD + a slightly larger onset re-feed (--provider cpu is the default)
python live_asr.py --vad firered --preroll 1.0

python live_asr.py                 # live mic (default FireRedVAD, falls back to silero)
python live_asr.py --vad silero
python live_asr.py --vad energy
python live_asr.py --wav test.wav  # feed a wav first (M0)
python live_asr.py --provider coreml
python live_asr.py --list-devices
```

| Flag | Default | Purpose |
|---|---|---|
| `--vad` | `firered` | backend: `firered` / `silero` / `energy` |
| `--vad-min-silence` | `0.7` | trailing silence (s) to mark end-of-sentence; larger = fewer cuts |
| `--vad-threshold` | `0.5` | speech-probability threshold for silero / firered |
| `--preroll` | `0.7` | onset re-feed (s): increase if sentence starts get clipped |
| `--tail-pad` | `1.0` | trailing silence at finalize (s); must be ≥ streaming chunk so tail words aren't dropped |
| `--energy-threshold` | `0.02` | RMS threshold for the energy backend |

## How endpointing works (design)

The streaming transducer emits text as audio is fed, but "end of sentence" must be decided externally. The `run()` loop:

1. VAD reports speech → create a recognizer stream and feed the **preroll buffer** (~0.7s of history before the stream opened) to recover the sentence start eaten by onset latency;
2. keep feeding frames, decode, refresh `[partial]`;
3. the VAD's `is_speech_detected()` **True→False** falling edge = confirmed end-of-sentence silence (already debounced by `min_silence`) → pad `--tail-pad` trailing silence, `input_finished()`, print `[final]`, and return to idle for the next sentence.

> Key point: it does **not** rely on the VAD's internal segment queue (`pop()`) to finalize. Silero does not reliably flush segments on an unbounded mic stream — relying on it gets stuck in partials with no final. Using the `is_speech_detected()` falling edge, all three backends finalize consecutive sentences reliably.

## Bring your own model

Drop any sherpa-onnx-compatible streaming model into `models/asr/` (transducer is auto-detected via encoder/decoder/joiner; single-model wenet-ctc is also supported). The `run()` loop and runtime need no changes.

## Credits & License

- **FireRedVAD** © FireRedTeam / Xiaohongshu, Apache-2.0 — <https://github.com/FireRedTeam/FireRedVAD> (weights: HuggingFace `FireRedTeam/FireRedVAD` / ModelScope `xukaituo/FireRedVAD`). Used via the official `pip install fireredvad`; this demo ships neither its code nor weights.
- **silero-vad** © Silero Team, MIT — invoked through the sherpa-onnx runtime.
- **sherpa-onnx** © k2-fsa, Apache-2.0.

This directory is Apache-2.0, consistent with X-ASR.
