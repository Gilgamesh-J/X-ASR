#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Minimal VAD -> streaming ASR demo (Python / sherpa-onnx)
========================================================

Pipeline:  microphone/wav (16k mono) -> VAD segmentation -> streaming zipformer
           decoding word-by-word -> print partial/final + latency.

This file validates "pipeline + streaming feel + latency" with a public streaming
model. To swap in your own VAD/ASR: export them to ONNX, drop them in models/ and
adjust the paths -- the loop here and the sherpa-onnx runtime stay untouched.

Usage:
    python live_asr.py                       # M1: live microphone
    python live_asr.py --wav test.wav        # M0: feed a wav (shake out model/feature issues first)
    python live_asr.py --provider coreml     # try CoreML acceleration on Apple Silicon
    python live_asr.py --list-devices        # list microphone devices
Default model paths: ASR=models/asr/  VAD=models/silero_vad.onnx  (see download_models.sh)
"""
import argparse
import glob
import os
import re
import shutil
import sys
import time
import unicodedata

import numpy as np
import sherpa_onnx


# --------------------------------------------------------------------------- #
# Single-line terminal refresh helpers: when refreshing the live partial, show
# only the tail that fits one line, so a long sentence does not wrap and leave
# leftovers that \r cannot clear. CJK glyphs count as 2 columns, so truncate by
# display width, not character count.
# --------------------------------------------------------------------------- #
def _char_cols(c):
    return 2 if unicodedata.east_asian_width(c) in ("W", "F") else 1


def _disp_width(s):
    return sum(_char_cols(c) for c in s)


def _fit_tail(s, max_cols):
    """Keep the tail of `s` whose display width is <= max_cols."""
    out, w = [], 0
    for c in reversed(s):
        cw = _char_cols(c)
        if w + cw > max_cols:
            break
        out.append(c)
        w += cw
    return "".join(reversed(out))

SAMPLE_RATE = 16000
VAD_WINDOW = 512  # silero vad fixed window (32ms at 16k)

# zipformer BPE inserts spaces between Han characters; do a CJK de-spacing pass
# (taken from X-ASR deployment).
_CJK = r"㐀-䶿一-鿿豈-﫿"
_CJK_PUNCT = re.escape("，。！？；：、（）《》〈〉【】「」『』“”‘’")
_ASCII_PUNCT = re.escape(",.!?;:%)]}")


def normalize_cjk(text):
    text = re.sub(rf"(?<=[{_CJK}])\s+(?=[{_CJK}])", "", text)
    text = re.sub(rf"(?<=[{_CJK}])\s+(?=[{_CJK_PUNCT}])", "", text)
    text = re.sub(rf"(?<=[{_CJK_PUNCT}])\s+(?=[{_CJK}])", "", text)
    text = re.sub(rf"(?<=[{_CJK_PUNCT}])\s+(?=[{_CJK_PUNCT}])", "", text)
    text = re.sub(rf"\s+(?=[{_ASCII_PUNCT}])", "", text)
    return text


# --------------------------------------------------------------------------- #
# Educational VAD: a pure-Python energy gate. Zero deps, zero model files, the
#   code IS the principle.
#   Idea: per-frame RMS energy -> above threshold = voiced. Voiced for
#         >= min_speech enters the "speaking" state; silence for >= min_silence
#         exits it and marks "end of sentence".
#   It duck-types the 4 methods sherpa's VAD exposes (accept_waveform /
#   is_speech_detected / empty / pop), so run() works with it unchanged.
#   The real silero VAD learns this voiced/silence decision with a small neural
#   net (far more robust to noise and level changes), but the state machine is
#   exactly this.
# --------------------------------------------------------------------------- #
class EnergyVad:
    def __init__(self, threshold=0.02, min_silence=0.5, min_speech=0.2, sample_rate=16000):
        self.threshold = threshold          # RMS threshold (float32 audio, speech ~0.02-0.1)
        self.min_silence = min_silence      # trailing silence to mark end-of-sentence
        self.min_speech = min_speech        # voiced duration before it counts as real speech
        self.sr = sample_rate
        self.in_speech = False              # currently inside a sentence?
        self.speech_run = 0.0               # consecutive voiced duration (s)
        self.silence_run = 0.0              # consecutive silence duration (s)
        self._pending = 0                   # finished sentences waiting for run() to consume

    def accept_waveform(self, window):
        window = np.asarray(window, dtype=np.float32)
        dt = len(window) / self.sr
        rms = float(np.sqrt(np.mean(window ** 2)) + 1e-9)
        if rms > self.threshold:            # -- voiced --
            self.speech_run += dt
            self.silence_run = 0.0
            if not self.in_speech and self.speech_run >= self.min_speech:
                self.in_speech = True
        else:                               # -- silence --
            self.silence_run += dt
            self.speech_run = 0.0
            if self.in_speech and self.silence_run >= self.min_silence:
                self.in_speech = False
                self._pending += 1          # end of a sentence, enqueue

    def is_speech_detected(self):
        return self.in_speech

    def empty(self):
        return self._pending == 0

    def pop(self):
        if self._pending > 0:
            self._pending -= 1


# --------------------------------------------------------------------------- #
# VAD #3: FireRedVAD (FireRedTeam / Xiaohongshu, DFSMN streaming VAD, 0.6M params,
#   97.57% frame-F1 on FLEURS-VAD-102, reported to beat silero/TEN/FunASR/WebRTC,
#   Apache-2.0).
#   Uses the official pip package: `pip install fireredvad` (which pulls torch /
#   kaldi_native_fbank, etc.); weights are downloaded to model_dir from HuggingFace
#   `FireRedTeam/FireRedVAD` (or ModelScope `xukaituo/FireRedVAD`). Here we adapt its
#   FireRedStreamVad to this demo's VAD interface (the same 4 duck-typed methods).
#   Lazy import: if firered is not selected, nothing is imported and the core demo
#   only needs sherpa-onnx.
# --------------------------------------------------------------------------- #
class FireRedVad:
    def __init__(self, model_dir="models/firered_vad", speech_threshold=0.5,
                 min_silence=0.7, min_speech=0.2, chunk_s=0.3):
        from fireredvad.stream_vad import FireRedStreamVad, FireRedStreamVadConfig
        FPS = 100  # 10ms frame shift -> 100 frames/second
        cfg = FireRedStreamVadConfig(
            speech_threshold=speech_threshold,
            min_speech_frame=max(1, int(round(min_speech * FPS))),
            min_silence_frame=max(1, int(round(min_silence * FPS))),
        )
        self.vad = FireRedStreamVad.from_pretrained(model_dir, cfg)
        self.vad.reset()
        self.chunk = int(chunk_s * SAMPLE_RATE)   # accumulate this many samples per feed (model cache carries across chunks)
        self._buf = np.zeros(0, dtype=np.float32)
        self.in_speech = False
        self._pending = 0

    def _run(self, chunk_f32):
        # FireRedVAD's features/CMVN are computed on the int16 scale, so convert [-1,1] back to int16
        i16 = (np.clip(chunk_f32, -1.0, 1.0) * 32767.0).astype(np.int16)
        for r in self.vad.detect_chunk(i16):
            if r.is_speech_start:
                self.in_speech = True
            if r.is_speech_end:
                self.in_speech = False
                self._pending += 1

    def accept_waveform(self, window):
        self._buf = np.concatenate([self._buf, np.asarray(window, dtype=np.float32)])
        while len(self._buf) >= self.chunk:
            self._run(self._buf[:self.chunk])
            self._buf = self._buf[self.chunk:]

    def is_speech_detected(self):
        return self.in_speech

    def empty(self):
        return self._pending == 0

    def pop(self):
        if self._pending > 0:
            self._pending -= 1


# --------------------------------------------------------------------------- #
# Model construction
# --------------------------------------------------------------------------- #
def find_asr_files(asr_dir):
    """Auto-detect the ASR layout: a joiner -> transducer; otherwise a single ctc model -> wenet_ctc."""
    onnx = sorted(glob.glob(os.path.join(asr_dir, "*.onnx")))
    onnx = [p for p in onnx if "vad" not in os.path.basename(p).lower()]
    if not onnx:
        raise SystemExit(f"[ERROR] no .onnx model under {asr_dir}. Run ./download_models.sh first")
    tokens = os.path.join(asr_dir, "tokens.txt")
    if not os.path.isfile(tokens):
        raise SystemExit(f"[ERROR] missing {tokens}")

    def pick(substr, prefer_no_int8=True):
        cand = [p for p in onnx if substr in os.path.basename(p).lower()]
        if prefer_no_int8:
            noint8 = [p for p in cand if "int8" not in os.path.basename(p).lower()]
            if noint8:
                return noint8[0]
        return cand[0] if cand else None

    enc, dec, join = pick("encoder"), pick("decoder"), pick("joiner")
    if join and not (enc and dec):
        miss = [n for n, v in [("encoder", enc), ("decoder", dec)] if not v]
        raise SystemExit(
            f"[ERROR] {asr_dir} has a joiner (= transducer model) but is missing {miss}."
            f"\n        encoder is the largest and often finishes downloading last -- "
            f"wait for it, or switch to a chunk dir that is fully downloaded.")
    if enc and dec and join:
        return "transducer", dict(tokens=tokens, encoder=enc, decoder=dec, joiner=join)

    # wenet / ctc: pick a single non-int8 model
    model = pick("model") or pick("ctc") or pick("encoder")
    if model is None:
        noint8 = [p for p in onnx if "int8" not in os.path.basename(p).lower()]
        model = (noint8 or onnx)[0]
    return "wenet-ctc", dict(tokens=tokens, model=model)


def build_recognizer(asr_dir, asr_type, provider, model_type=""):
    kind, files = find_asr_files(asr_dir)
    if asr_type != "auto":
        kind = asr_type
    print(f"[ASR] type={kind}  provider={provider}  model_type={model_type or 'auto'}")
    for k, v in files.items():
        print(f"      {k}: {v}")
    common = dict(num_threads=2, provider=provider, decoding_method="greedy_search",
                  enable_endpoint_detection=False)  # endpointing is handled by the VAD
    if kind == "transducer":
        return sherpa_onnx.OnlineRecognizer.from_transducer(**files, model_type=model_type, **common)
    if kind == "wenet-ctc":
        return sherpa_onnx.OnlineRecognizer.from_wenet_ctc(
            tokens=files["tokens"], model=files["model"],
            chunk_size=16, num_left_chunks=4, **common)
    raise SystemExit(f"[ERROR] unsupported asr-type: {kind}")


def _build_silero(vad_model, threshold, min_silence, min_speech, provider):
    if not os.path.isfile(vad_model):
        raise SystemExit(f"[ERROR] VAD model not found: {vad_model} (or use --vad energy, which needs no model)")
    cfg = sherpa_onnx.VadModelConfig()
    cfg.silero_vad.model = vad_model
    cfg.silero_vad.threshold = threshold
    cfg.silero_vad.min_silence_duration = min_silence
    cfg.silero_vad.min_speech_duration = min_speech
    cfg.silero_vad.window_size = VAD_WINDOW
    cfg.sample_rate = SAMPLE_RATE
    cfg.provider = provider
    print(f"[VAD] silero {vad_model}  threshold={threshold} min_silence={min_silence}s")
    return sherpa_onnx.VoiceActivityDetector(cfg, buffer_size_in_seconds=30)


def build_vad(kind, vad_model, threshold, min_silence, min_speech, energy_threshold, provider,
              firered_dir="models/firered_vad"):
    if kind == "energy":
        print(f"[VAD] energy (pure-Python, educational)  threshold={energy_threshold} "
              f"min_silence={min_silence}s min_speech={min_speech}s")
        return EnergyVad(threshold=energy_threshold, min_silence=min_silence, min_speech=min_speech)

    if kind == "firered":
        # Prefer FireRedVAD by default; if the package is missing (no `pip install
        # fireredvad`) or the weights are absent, fall back to silero so the demo
        # always runs.
        try:
            vad = FireRedVad(model_dir=firered_dir, speech_threshold=threshold,
                             min_silence=min_silence, min_speech=min_speech)
            print(f"[VAD] FireRedVAD (DFSMN streaming)  threshold={threshold} "
                  f"min_silence={min_silence}s min_speech={min_speech}s")
            return vad
        except ImportError:
            print("[VAD] fireredvad not installed (pip install fireredvad); falling back to silero.",
                  file=sys.stderr)
        except Exception as e:
            print(f"[VAD] FireRedVAD unavailable ({type(e).__name__}: {e}); falling back to silero."
                  f"\n      Weights can be downloaded to {firered_dir} (see download_models.sh).",
                  file=sys.stderr)
        return _build_silero(vad_model, threshold, min_silence, min_speech, provider)

    # silero (neural VAD, robust; only depends on sherpa-onnx)
    return _build_silero(vad_model, threshold, min_silence, min_speech, provider)


# --------------------------------------------------------------------------- #
# Audio input: uniformly yields 512-sample float32 windows (range [-1, 1])
# --------------------------------------------------------------------------- #
def resample_to_16k(x, sr):
    if sr == SAMPLE_RATE:
        return x.astype("float32")
    n = int(round(len(x) * SAMPLE_RATE / sr))
    xp = np.linspace(0.0, 1.0, num=len(x), endpoint=False)
    xq = np.linspace(0.0, 1.0, num=n, endpoint=False)
    return np.interp(xq, xp, x).astype("float32")  # linear resample, good enough for a demo


def iter_windows_wav(path):
    import soundfile as sf
    data, sr = sf.read(path, dtype="float32", always_2d=True)
    data = data.mean(axis=1)  # to mono
    if sr != SAMPLE_RATE:
        print(f"[wav] {sr}Hz -> 16k linear resample (prefer a 16k wav directly)")
        data = resample_to_16k(data, sr)
    n = (len(data) // VAD_WINDOW) * VAD_WINDOW
    for i in range(0, n, VAD_WINDOW):
        yield data[i:i + VAD_WINDOW]
    # pad trailing silence so the VAD can close the last sentence (needs >= min_silence to trigger)
    yield np.zeros(int(1.0 * SAMPLE_RATE), dtype="float32")


def iter_windows_mic(device_index):
    import queue
    import sounddevice as sd
    q = queue.Queue()

    def callback(indata, frames, t, status):
        if status:
            print(status, file=sys.stderr)
        q.put(indata[:, 0].copy())

    print("[mic] speak now (Ctrl-C to quit)...")
    buf = np.zeros(0, dtype="float32")
    with sd.InputStream(samplerate=SAMPLE_RATE, channels=1, dtype="float32",
                        blocksize=VAD_WINDOW, device=device_index, callback=callback):
        while True:
            buf = np.concatenate([buf, q.get()])
            while len(buf) >= VAD_WINDOW:
                yield buf[:VAD_WINDOW]
                buf = buf[VAD_WINDOW:]


# --------------------------------------------------------------------------- #
# Core state machine: VAD gating + streaming decoding (shared by M0/M1)
# --------------------------------------------------------------------------- #
def run(recognizer, vad, windows, fmt=lambda s: s, tail_pad=1.0, preroll_s=0.7):
    stream = None
    active = False          # inside a sentence?
    seg_samples = 0         # samples fed for the current sentence (for RTF)
    preroll = []            # ring buffer of recent windows, to recover the sentence start
    # The VAD only reports "speech" after min_speech, and FireRed also accumulates a
    # 0.3s chunk, so by the time it confirms, the start is already 0.3-0.6s in the past.
    # Re-feed that much history to avoid clipping each sentence start. Larger = more
    # complete starts (cost: decoding a bit more leading silence).
    PREROLL = max(1, int(preroll_s * SAMPLE_RATE / VAD_WINDOW))

    def term_cols():
        return shutil.get_terminal_size((80, 24)).columns

    def clear_line():
        sys.stdout.write("\r" + " " * (term_cols() - 1) + "\r")
        sys.stdout.flush()

    def show_partial(text):
        # Show only the tail that fits one terminal line, pad with spaces to wipe the
        # previous frame's leftovers, and never wrap.
        cols = term_cols()
        prefix = "[partial] "
        tail = _fit_tail(text, cols - len(prefix) - 1)
        pad = max(0, cols - 1 - len(prefix) - _disp_width(tail))
        sys.stdout.write("\r" + prefix + tail + " " * pad)
        sys.stdout.flush()

    def finalize():
        # Close the sentence: pad trailing silence to flush the last word (must be >=
        # the streaming model's algorithmic latency / chunk size), then print final.
        nonlocal active, stream
        t0 = time.time()
        stream.accept_waveform(SAMPLE_RATE, np.zeros(int(tail_pad * SAMPLE_RATE), dtype="float32"))
        stream.input_finished()
        while recognizer.is_ready(stream):
            recognizer.decode_stream(stream)
        final = fmt(recognizer.get_result(stream))
        dt = time.time() - t0
        dur = seg_samples / SAMPLE_RATE
        clear_line()
        if final.strip():
            print(f"[final  ] {final}    "
                  f"(finalize {dt * 1000:.0f}ms, seg {dur:.1f}s, RTF {dt / max(dur, 1e-6):.2f})")
        active = False
        stream = None

    for w in windows:
        vad.accept_waveform(w)
        speech = vad.is_speech_detected()

        # speech onset -> open a new stream and re-feed the sentence start from preroll
        if speech and not active:
            active = True
            stream = recognizer.create_stream()
            seg_samples = 0
            for pw in preroll:
                stream.accept_waveform(SAMPLE_RATE, pw)
                seg_samples += len(pw)

        # inside a sentence: feed frames, decode, refresh the partial
        if active:
            stream.accept_waveform(SAMPLE_RATE, w)
            seg_samples += len(w)
            while recognizer.is_ready(stream):
                recognizer.decode_stream(stream)
            partial = fmt(recognizer.get_result(stream))
            if partial:
                show_partial(partial)

        # speech -> silence falling edge: the sentence ended, so finalize and go idle
        # for the next one. is_speech_detected already includes the min_silence hangover,
        # so flipping to False means end-of-sentence silence is confirmed -- hence we do
        # NOT rely on vad.pop() (silero does not reliably flush segments on a live stream,
        # which would get stuck with no final).
        if active and not speech:
            finalize()

        # maintain the preroll ring buffer + drain the VAD segment queue (used and
        # discarded, to avoid unbounded growth)
        preroll.append(w)
        if len(preroll) > PREROLL:
            preroll.pop(0)
        while not vad.empty():
            vad.pop()

    # input stream ended (wav tail) while still inside a sentence: finalize as a fallback
    if active and stream is not None:
        finalize()


# --------------------------------------------------------------------------- #
def main():
    ap = argparse.ArgumentParser(description="Minimal VAD -> streaming ASR demo (sherpa-onnx)")
    ap.add_argument("--asr-dir", default="models/asr", help="ASR model directory")
    ap.add_argument("--asr-type", default="auto", choices=["auto", "transducer", "wenet-ctc"])
    ap.add_argument("--vad", default="firered", choices=["silero", "energy", "firered"],
                    help="firered=FireRedVAD (DFSMN streaming, default; needs pip install fireredvad, "
                         "auto-falls back to silero if package/weights are missing); "
                         "silero=sherpa neural VAD; energy=pure-Python energy VAD (no model)")
    ap.add_argument("--vad-model", default="models/silero_vad.onnx")
    ap.add_argument("--energy-threshold", type=float, default=0.02, help="RMS threshold for the energy VAD")
    ap.add_argument("--wav", default=None, help="feed a wav for M0; omit for microphone M1")
    ap.add_argument("--provider", default="cpu", help="cpu / coreml (Apple Silicon)")
    ap.add_argument("--model-type", default="", help="empty=auto-detect; use zipformer2 for X-ASR's zipformer")
    ap.add_argument("--no-cjk-normalize", action="store_true", help="disable CJK de-spacing normalization")
    ap.add_argument("--device-index", type=int, default=None, help="microphone device index")
    ap.add_argument("--list-devices", action="store_true")
    ap.add_argument("--vad-threshold", type=float, default=0.5)
    ap.add_argument("--vad-min-silence", type=float, default=0.7,
                    help="trailing silence to mark end-of-sentence (s); larger = fewer cuts")
    ap.add_argument("--vad-min-speech", type=float, default=0.25)
    ap.add_argument("--tail-pad", type=float, default=1.0,
                    help="trailing silence padded at finalize (s); must be >= chunk size to not drop tail words")
    ap.add_argument("--preroll", type=float, default=0.7,
                    help="sentence-start re-feed (s): recovers the start eaten by VAD onset latency; "
                         "increase if starts are clipped")
    args = ap.parse_args()

    if args.list_devices:
        import sounddevice as sd
        print(sd.query_devices())
        return

    recognizer = build_recognizer(args.asr_dir, args.asr_type, args.provider, args.model_type)
    vad = build_vad(args.vad, args.vad_model, args.vad_threshold, args.vad_min_silence,
                    args.vad_min_speech, args.energy_threshold, args.provider)
    fmt = (lambda s: s) if args.no_cjk_normalize else normalize_cjk

    if args.wav:
        print(f"[M0] file input: {args.wav}\n" + "-" * 50)
        run(recognizer, vad, iter_windows_wav(args.wav), fmt, args.tail_pad, args.preroll)
        print("-" * 50 + "\n[done]")
    else:
        print("[M1] live microphone\n" + "-" * 50)
        try:
            run(recognizer, vad, iter_windows_mic(args.device_index), fmt, args.tail_pad, args.preroll)
        except KeyboardInterrupt:
            print("\n[exit]")


if __name__ == "__main__":
    main()
