#!/usr/bin/env python3
#
# Copyright (c)  2025  Xiaomi Corporation (authors: Fangjun Kuang)


import torch

import kaldi_native_fbank as knf


def _test_istft_impl(n_fft, normalized, window_type, center):
    print(n_fft, normalized, window_type, center)
    hop_length = n_fft // 4
    win_length = n_fft

    window = None

    if window_type == "hann":
        window = torch.hann_window(win_length)
    elif window_type == "hann2":
        window = torch.hann_window(win_length).pow(0.5)

    samples = torch.rand(20000)

    torch_result = torch.stft(
        samples,
        n_fft=n_fft,
        hop_length=hop_length,
        center=center,
        return_complex=True,
        normalized=normalized,
        window=window,
    )
    # torch_result: (n_fft/2+1, num_frames), complex tensor

    torch_result = torch.istft(
        torch_result,
        n_fft=n_fft,
        hop_length=hop_length,
        window=window,
        center=center,
        normalized=normalized,
    )

    config = knf.StftConfig(
        n_fft=n_fft,
        hop_length=hop_length,
        win_length=n_fft,
        window_type="hann",
        center=center,
        pad_mode="reflect",
        normalized=normalized,
        window=window.tolist() if window is not None else [],
    )
    stft = knf.Stft(config)
    k = stft(samples.tolist())
    istft = knf.IStft(config)
    knf_result = istft(k)
    knf_result = torch.tensor(knf_result)
    assert torch.allclose(torch_result, knf_result, atol=1e-1), (
        (torch_result - knf_result).abs().max(),
        (torch_result - knf_result).abs().sum(),
        n_fft,
        normalized,
        window_type,
        center,
        samples.shape,
        torch_result,
        knf_result,
    )


def test_istft():
    n_fft_list = [6, 10, 400, 1000]
    n_fft_list += [64, 128, 256, 512, 1024, 2048, 4096]
    normalized_list = [False, True]
    window_type_list = ["hann", "", "hann2"]
    center_list = [True]

    for n_fft in n_fft_list:
        for normalized in normalized_list:
            for window_type in window_type_list:
                for center in center_list:
                    _test_istft_impl(
                        n_fft=n_fft,
                        normalized=normalized,
                        window_type=window_type,
                        center=center,
                    )


def main():
    torch.manual_seed(20250308)
    test_istft()


if __name__ == "__main__":
    main()
