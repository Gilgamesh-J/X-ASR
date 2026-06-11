#!/usr/bin/env python3
# -*- coding: utf-8 -*-

import argparse
import asyncio
import json
import logging
from dataclasses import dataclass
from typing import Optional

import numpy as np
import websockets

from sherpa_streaming_infer import SherpaStreamingASR


logging.basicConfig(
    format="%(asctime)s %(levelname)s [%(filename)s:%(lineno)d] %(message)s",
    level=logging.INFO,
)


def get_parser():
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", type=str, default="0.0.0.0")
    parser.add_argument("--port", type=int, default=8766)

    parser.add_argument("--tokens", type=str, default="models/chunk-160ms-model/tokens.txt")
    parser.add_argument("--encoder", type=str, default="models/chunk-160ms-model/encoder-160ms.onnx")
    parser.add_argument("--decoder", type=str, default="models/chunk-160ms-model/decoder-160ms.onnx")
    parser.add_argument("--joiner", type=str, default="models/chunk-160ms-model/joiner-160ms.onnx")

    parser.add_argument("--provider", type=str, default="cpu")
    parser.add_argument("--sample-rate", type=int, default=16000)
    parser.add_argument("--feature-dim", type=int, default=80)
    parser.add_argument("--num-threads", type=int, default=1)
    parser.add_argument("--decoding-method", type=str, default="greedy_search")
    parser.add_argument("--model-type", type=str, default="zipformer2")
    parser.add_argument("--enable-endpoint-detection", type=int, default=0)
    parser.add_argument("--text-format", type=str, default="lower")  # none/lower/capitalize
    return parser


@dataclass
class SessionState:
    asr: SherpaStreamingASR
    sample_rate: int = 16000


def build_asr(args) -> SherpaStreamingASR:
    return SherpaStreamingASR(
        tokens=args.tokens,
        encoder=args.encoder,
        decoder=args.decoder,
        joiner=args.joiner,
        provider=args.provider,
        sample_rate=args.sample_rate,
        feature_dim=args.feature_dim,
        num_threads=args.num_threads,
        decoding_method=args.decoding_method,
        model_type=args.model_type,
        enable_endpoint_detection=bool(args.enable_endpoint_detection),
        text_format=args.text_format,
    )


async def handle_connection(websocket, args):
    logging.info("client connected")
    session: Optional[SessionState] = None

    try:
        async for message in websocket:
            # 二进制消息：默认视作 int16 PCM 音频块
            if isinstance(message, bytes):
                if session is None:
                    await websocket.send(
                        json.dumps({"type": "error", "text": "session not started"}, ensure_ascii=False)
                    )
                    continue

                pcm = np.frombuffer(message, dtype=np.int16).astype(np.float32) / 32768.0
                session.asr.accept_waveform(pcm, sample_rate=session.sample_rate)
                session.asr.decode()

                partial = session.asr.get_partial_result()
                await websocket.send(
                    json.dumps({"type": "partial", "text": partial}, ensure_ascii=False)
                )
                continue

            # 文本消息：JSON 控制协议
            payload = json.loads(message)
            msg_type = payload.get("type", "")

            if msg_type == "start":
                # 可选覆盖采样率
                client_sr = int(payload.get("sample_rate", args.sample_rate))
                session = SessionState(
                    asr=build_asr(args),
                    sample_rate=client_sr,
                )
                await websocket.send(
                    json.dumps({"type": "started", "sample_rate": client_sr}, ensure_ascii=False)
                )

            elif msg_type == "end":
                if session is None:
                    await websocket.send(
                        json.dumps({"type": "error", "text": "session not started"}, ensure_ascii=False)
                    )
                    continue

                session.asr.input_finished()
                final_text = session.asr.get_final_result()
                latency = session.asr.get_first_partial_latency()

                await websocket.send(
                    json.dumps(
                        {
                            "type": "final",
                            "text": final_text,
                            "first_partial_latency": latency,
                        },
                        ensure_ascii=False,
                    )
                )

            elif msg_type == "reset":
                session = SessionState(
                    asr=build_asr(args),
                    sample_rate=args.sample_rate,
                )
                await websocket.send(
                    json.dumps({"type": "reset_ok"}, ensure_ascii=False)
                )

            elif msg_type == "ping":
                await websocket.send(
                    json.dumps({"type": "pong"}, ensure_ascii=False)
                )

            else:
                await websocket.send(
                    json.dumps(
                        {"type": "error", "text": f"unknown message type: {msg_type}"},
                        ensure_ascii=False,
                    )
                )

    except websockets.ConnectionClosed:
        logging.info("client disconnected")


async def main():
    args = get_parser().parse_args()
    logging.info(vars(args))

    async with websockets.serve(
        lambda ws: handle_connection(ws, args),
        args.host,
        args.port,
        max_size=None,
    ):
        logging.info("server started at ws://%s:%s", args.host, args.port)
        await asyncio.Future()


if __name__ == "__main__":
    asyncio.run(main())
