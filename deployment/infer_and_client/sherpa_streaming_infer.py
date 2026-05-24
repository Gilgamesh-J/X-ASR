#!/usr/bin/env python3
# -*- coding: utf-8 -*-

import re
import time
from dataclasses import dataclass
from typing import Optional

import numpy as np
import sherpa_onnx


_CJK_RANGE = r"\u3400-\u4dbf\u4e00-\u9fff\uf900-\ufaff"
_CJK_PUNCT = re.escape("，。！？；：、（）《》〈〉【】「」『』“”‘’")
_ASCII_PUNCT_NO_LEADING_SPACE = re.escape(",.!?;:%)]}")


def _normalize_cjk_spacing(text: str) -> str:
    text = re.sub(rf"(?<=[{_CJK_RANGE}])\s+(?=[{_CJK_RANGE}])", "", text)
    text = re.sub(rf"(?<=[{_CJK_RANGE}])\s+(?=[{_CJK_PUNCT}])", "", text)
    text = re.sub(rf"(?<=[{_CJK_PUNCT}])\s+(?=[{_CJK_RANGE}])", "", text)
    text = re.sub(rf"(?<=[{_CJK_PUNCT}])\s+(?=[{_CJK_PUNCT}])", "", text)
    text = re.sub(rf"\s+(?=[{_ASCII_PUNCT_NO_LEADING_SPACE}])", "", text)
    return text


def format_text(text: str, mode: str = "none") -> str:
    if mode == "lower":
        text = text.lower()
    elif mode == "capitalize":
        text = text[:1].upper() + text[1:].lower() if text else text
    return _normalize_cjk_spacing(text)


@dataclass
class StreamingStats:
    start_time: Optional[float] = None
    first_non_empty_partial_time: Optional[float] = None

    def reset(self):
        self.start_time = None
        self.first_non_empty_partial_time = None


class SherpaStreamingASR:
    def __init__(
        self,
        tokens: str,
        encoder: str,
        decoder: str,
        joiner: str,
        provider: str = "cuda",
        sample_rate: int = 16000,
        feature_dim: int = 80,
        num_threads: int = 1,
        decoding_method: str = "greedy_search",
        model_type: str = "zipformer2",
        enable_endpoint_detection: bool = False,
        text_format: str = "none",   # none / lower / capitalize
    ):
        self.tokens = tokens
        self.encoder = encoder
        self.decoder = decoder
        self.joiner = joiner
        self.provider = provider
        self.sample_rate = sample_rate
        self.feature_dim = feature_dim
        self.num_threads = num_threads
        self.decoding_method = decoding_method
        self.model_type = model_type
        self.enable_endpoint_detection = enable_endpoint_detection
        self.text_format = text_format

        self.recognizer = sherpa_onnx.OnlineRecognizer.from_transducer(
            tokens=self.tokens,
            encoder=self.encoder,
            decoder=self.decoder,
            joiner=self.joiner,
            num_threads=self.num_threads,
            sample_rate=self.sample_rate,
            feature_dim=self.feature_dim,
            decoding_method=self.decoding_method,
            provider=self.provider,
            model_type=self.model_type,
            enable_endpoint_detection=self.enable_endpoint_detection,
        )

        self.stats = StreamingStats()
        self.reset()

    def reset(self):
        self.stream = self.recognizer.create_stream()
        self.last_result = ""
        self.partial_result = ""
        self.final_result = ""
        self.finished = False
        self.stats.reset()

    def _ensure_started(self):
        if self.stats.start_time is None:
            self.stats.start_time = time.perf_counter()

    def _format(self, text: str) -> str:
        return format_text(text, self.text_format)

    def accept_waveform(self, samples: np.ndarray, sample_rate: Optional[int] = None):
        if sample_rate is None:
            sample_rate = self.sample_rate

        self._ensure_started()

        if not isinstance(samples, np.ndarray):
            samples = np.asarray(samples)

        samples = samples.astype(np.float32).reshape(-1)
        self.stream.accept_waveform(sample_rate, samples)

    def decode(self) -> int:
        """
        Decode as much as possible for the current stream.
        Returns:
            number of decode steps performed
        """
        num_decodes = 0

        while self.recognizer.is_ready(self.stream):
            self.recognizer.decode_stream(self.stream)
            result = self.recognizer.get_result(self.stream)
            result = self._format(result)

            if result != self.last_result:
                self.partial_result = result
                self.last_result = result

                if result and self.stats.first_non_empty_partial_time is None:
                    self.stats.first_non_empty_partial_time = (
                        time.perf_counter() - self.stats.start_time
                    )

            num_decodes += 1

        return num_decodes

    def get_partial_result(self) -> str:
        return self.partial_result

    def input_finished(self):
        self.finished = True
        self.stream.input_finished()

    def get_final_result(self) -> str:
        if not self.finished:
            self.input_finished()

        while self.recognizer.is_ready(self.stream):
            self.recognizer.decode_stream(self.stream)

        result = self.recognizer.get_result(self.stream)
        result = self._format(result)
        self.final_result = result
        self.partial_result = result
        self.last_result = result
        return self.final_result

    def get_first_partial_latency(self) -> Optional[float]:
        return self.stats.first_non_empty_partial_time

    def is_endpoint(self) -> bool:
        if hasattr(self.recognizer, "is_endpoint"):
            return self.recognizer.is_endpoint(self.stream)
        return False
