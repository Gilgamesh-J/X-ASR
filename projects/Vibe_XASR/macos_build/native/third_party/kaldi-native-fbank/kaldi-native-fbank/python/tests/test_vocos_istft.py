#!/usr/bin/env python3
#
# Copyright (c)  2025 (authors: Bangwen He)

import torch
import torch.nn as nn
import kaldi_native_fbank as knf


# copied from [vocos heads](https://github.com/gemelo-ai/vocos/blob/main/vocos/spectral_ops.py#L7)
"""
MIT License

Copyright (c) 2023 Charactr Inc.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
"""
class ISTFT(nn.Module):
    """
    Custom implementation of ISTFT since torch.istft doesn't allow custom padding (other than `center=True`) with
    windowing. This is because the NOLA (Nonzero Overlap Add) check fails at the edges.
    See issue: https://github.com/pytorch/pytorch/issues/62323
    Specifically, in the context of neural vocoding we are interested in "same" padding analogous to CNNs.
    The NOLA constraint is met as we trim padded samples anyway.

    Args:
        n_fft (int): Size of Fourier transform.
        hop_length (int): The distance between neighboring sliding window frames.
        win_length (int): The size of window frame and STFT filter.
        padding (str, optional): Type of padding. Options are "center" or "same". Defaults to "same".
    """

    def __init__(self, n_fft: int, hop_length: int, win_length: int, padding: str = "same"):
        super().__init__()
        if padding not in ["center", "same"]:
            raise ValueError("Padding must be 'center' or 'same'.")
        self.padding = padding
        self.n_fft = n_fft
        self.hop_length = hop_length
        self.win_length = win_length
        window = torch.hann_window(win_length)
        self.register_buffer("window", window)

    def forward(self, spec: torch.Tensor) -> torch.Tensor:
        """
        Compute the Inverse Short Time Fourier Transform (ISTFT) of a complex spectrogram.

        Args:
            spec (Tensor): Input complex spectrogram of shape (B, N, T), where B is the batch size,
                            N is the number of frequency bins, and T is the number of time frames.

        Returns:
            Tensor: Reconstructed time-domain signal of shape (B, L), where L is the length of the output signal.
        """
        if self.padding == "center":
            # Fallback to pytorch native implementation
            return torch.istft(spec, self.n_fft, self.hop_length, self.win_length, self.window, center=True)
        elif self.padding == "same":
            pad = (self.win_length - self.hop_length) // 2
        else:
            raise ValueError("Padding must be 'center' or 'same'.")

        assert spec.dim() == 3, "Expected a 3D tensor as input"
        B, N, T = spec.shape

        # Inverse FFT
        ifft = torch.fft.irfft(spec, self.n_fft, dim=1, norm="backward")
        ifft = ifft * self.window[None, :, None]

        # Overlap and Add
        output_size = (T - 1) * self.hop_length + self.win_length
        y = torch.nn.functional.fold(
            ifft, output_size=(1, output_size), kernel_size=(1, self.win_length), stride=(1, self.hop_length),
        )[:, 0, 0, pad:-pad]

        # Window envelope
        window_sq = self.window.square().expand(1, T, -1).transpose(1, 2)
        window_envelope = torch.nn.functional.fold(
            window_sq, output_size=(1, output_size), kernel_size=(1, self.win_length), stride=(1, self.hop_length),
        ).squeeze()[pad:-pad]

        # Normalize
        assert (window_envelope > 1e-11).all()
        y = y / window_envelope

        return y


def test_vocos_istft_impl(num_frames=768, n_fft=1024, hop_length=256, win_length=1024):
    real = torch.randn((1, n_fft//2+1, num_frames))
    imag = torch.randn((1, n_fft//2+1, num_frames))
    spec = torch.complex(real, imag)
    vocos_istft = ISTFT(n_fft, hop_length, win_length, padding="same")
    vocos_out = vocos_istft(spec)

    knf_config = knf.StftConfig(
        n_fft=n_fft,
        hop_length=hop_length,
        win_length=win_length,
        window_type="hann",
        center=True,
        pad_mode="replicate",
        normalized=False,
    )
    knf_istft = knf.IStft(knf_config)
    knf_real = real.transpose(1, 2)
    knf_imag = imag.transpose(1, 2)
    knf_stft_result = knf.StftResult(
        real=knf_real.flatten().tolist(),
        imag=knf_imag.flatten().tolist(),
        num_frames=num_frames,
    )
    knf_out = knf_istft(knf_stft_result)
    knf_out = torch.tensor(knf_out).unsqueeze(0)

    pad = (n_fft - win_length + hop_length) // 2  # i.e. hop_length // 2
    vocos_out = vocos_out[:, pad:-pad]

    assert torch.allclose(vocos_out, knf_out, atol=1e-5), (
        (vocos_out - knf_out).abs().max(),
        (vocos_out - knf_out).abs().sum(),
        num_frames,
        n_fft,
        hop_length,
        win_length,
        vocos_out.shape,
        vocos_out,
        knf_out.shape,
        knf_out,
    )

    print(f"Passed. num_frames={num_frames}, n_fft={n_fft}, hop_length={hop_length}, win_length={win_length}, pad(vocos-knf)={pad}")
    print("=" * 30)

def test_vocos_istft():
    torch.manual_seed(20250428)
    num_frames_list = [256, 512, 768, 1024]
    n_fft_list = [512, 1024]
    hop_list = [128, 256]

    for num_frames in num_frames_list:
        for n_fft in n_fft_list:
            for hop in hop_list:
                test_vocos_istft_impl(num_frames=num_frames, n_fft=n_fft, hop_length=hop, win_length=n_fft)


if __name__ == "__main__":
    test_vocos_istft()
