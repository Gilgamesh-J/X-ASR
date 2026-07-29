#!/usr/bin/env python3
# -*- coding: utf-8 -*-

import argparse
import asyncio
import contextlib
import json

import numpy as np
import soundfile as sf
import websockets


def get_parser():
    parser = argparse.ArgumentParser()
    parser.add_argument("--server-uri", type=str, default="ws://127.0.0.1:8766")
    parser.add_argument("--wav", type=str, required=True)
    parser.add_argument("--chunk-ms", type=int, default=100)
    parser.add_argument("--simulate-realtime", type=int, default=1)
    return parser


def load_audio_as_mono_int16(wav_path: str, target_sr: int = 16000):
    audio, sr = sf.read(wav_path, always_2d=False)

    if audio.ndim == 2:
        audio = audio.mean(axis=1)

    if np.issubdtype(audio.dtype, np.integer):
        max_val = np.iinfo(audio.dtype).max
        audio = audio.astype(np.float32) / float(max_val)
    else:
        audio = audio.astype(np.float32)

    if sr != target_sr:
        import librosa
        audio = librosa.resample(audio, orig_sr=sr, target_sr=target_sr)
        sr = target_sr

    audio = np.clip(audio, -1.0, 1.0)
    audio_int16 = (audio * 32767.0).astype(np.int16)
    return audio_int16, sr


async def recv_loop(ws, final_event: asyncio.Event):
    async for msg in ws:
        data = json.loads(msg)
        print("[SERVER]", data, flush=True)
        if data.get("type") == "final":
            final_event.set()


async def main():
    args = get_parser().parse_args()

    wav, sr = load_audio_as_mono_int16(args.wav, target_sr=16000)
    chunk_samples = int(sr * args.chunk_ms / 1000)

    async with websockets.connect(args.server_uri, max_size=None) as ws:
        final_event = asyncio.Event()
        recv_task = asyncio.create_task(recv_loop(ws, final_event))

        await ws.send(json.dumps({"type": "start", "sample_rate": sr}))

        start = 0
        while start < len(wav):
            end = min(start + chunk_samples, len(wav))
            chunk = wav[start:end].tobytes()
            await ws.send(chunk)

            if args.simulate_realtime:
                await asyncio.sleep(args.chunk_ms / 1000.0)

            start = end

        await ws.send(json.dumps({"type": "end"}))

        with contextlib.suppress(asyncio.TimeoutError):
            await asyncio.wait_for(final_event.wait(), timeout=10.0)

        recv_task.cancel()
        with contextlib.suppress(asyncio.CancelledError):
            await recv_task


if __name__ == "__main__":
    asyncio.run(main())
