#!/usr/bin/env python3
#
# Copyright (c)  2025  Xiaomi Corporation (authors: Fangjun Kuang)


import torch

import kaldi_native_fbank as knf


def test_stft_config():
    config = knf.StftConfig(
        n_fft=512,
        hop_length=128,
        win_length=512,
        window_type="povey",
        center=True,
        pad_mode="reflect",
        normalized=False,
    )
    print(config)


def _test_stft_impl(n_fft, normalized, window_type="", center=False):
    hop_length = n_fft // 4
    win_length = n_fft

    window = None

    if window_type == "hann":
        window = torch.hann_window(win_length)
    elif window_type == "hann2":
        window = torch.hann_window(win_length).pow(0.5)

    samples = torch.rand(50000)
    config = knf.StftConfig(
        n_fft=n_fft,
        hop_length=hop_length,
        win_length=n_fft,
        window_type=window_type,
        center=center,
        pad_mode="reflect",
        normalized=normalized,
        window=window.tolist() if window is not None else [],
    )
    torch_result = torch.stft(
        samples,
        n_fft=n_fft,
        hop_length=hop_length,
        center=center,
        return_complex=False,
        normalized=normalized,
        window=window,
    )
    # y.shape: (n_fft/2+1, num_frames, 2)

    stft = knf.Stft(config)
    k = stft(samples.tolist())
    knf_result = torch.tensor([k.real, k.imag]).reshape(2, k.num_frames, -1)
    # now knf_result is (2, num_frames, n_fft/2+1)

    knf_result = knf_result.permute(2, 1, 0)

    assert torch.allclose(torch_result, knf_result, atol=1e-3), (
        torch_result,
        knf_result,
        torch_result.shape,
        knf_result.shape,
    )
    print(f"Passed: n_fft={n_fft}, normalized={normalized}, window_type={window_type}")


def test_stft():
    n_fft_list = [6, 10, 400, 1000]
    n_fft_list += [8, 64, 128, 256, 512, 1024, 2048, 4096]
    normalized_list = [True, False]
    window_type_list = ["", "hann", "hann2"]
    center_list = [True, False]

    for n_fft in n_fft_list:
        for normalized in normalized_list:
            for window_type in window_type_list:
                for center in center_list:
                    _test_stft_impl(
                        n_fft=n_fft,
                        normalized=normalized,
                        window_type=window_type,
                        center=center,
                    )


def main():
    torch.manual_seed(20250308)
    test_stft_config()
    test_stft()


if __name__ == "__main__":
    main()
