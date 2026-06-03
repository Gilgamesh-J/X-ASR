#!/usr/bin/env python3

# see also https://colab.research.google.com/drive/1NxiyngCA4lDRy5BxqTVDLGDPudWKRwEs?usp=sharing

import kaldi_native_fbank as knf
import numpy as np

sample_rate = 16000
num_seconds = 1

frame_length_ms = 25
frame_shift_ms = 10

frame_length = int(frame_length_ms * sample_rate / 1000)
frame_shift = int(frame_shift_ms * sample_rate / 1000)


def remove_dc_offset(samples):
    mean = np.mean(samples)
    return samples - mean


def preemphasize(samples, coeff=0.97):
    ans = np.empty_like(samples)

    ans[0] = samples[0] - coeff * samples[0]
    ans[1:] = samples[1:] - coeff * samples[:-1]

    return ans


def get_hann_window(n: int):
    # 请看 https://docs.pytorch.org/docs/stable/generated/torch.hann_window.html
    k = np.arange(n)
    return 0.5 * (1 - np.cos(2 * np.pi * k / (n - 1)))


def compute_fft(samples, nfft=512):
    return np.fft.rfft(samples, nfft)


def compute_power_spectrum(fft_bins):
    return np.abs(fft_bins) ** 2


def get_mel_filter_bank_matrix():
    mel_opts = knf.MelBanksOptions()
    mel_opts.num_bins = 23

    frame_opts = knf.FrameExtractionOptions()
    frame_opts.window_type = "hann"
    mel_bank = knf.MelBanks(opts=mel_opts, frame_opts=frame_opts)
    return mel_bank.get_matrix()


def compute_fbank(samples):
    samples = remove_dc_offset(samples)
    samples = preemphasize(samples)

    window = get_hann_window(samples.shape[0])
    samples = samples * window

    fft_bins = compute_fft(samples)
    power_spec = compute_power_spectrum(fft_bins)

    matrix = get_mel_filter_bank_matrix()

    f = np.matmul(matrix, power_spec.reshape(-1, 1)).squeeze(1)

    f = np.where(f == 0, np.finfo(float).eps, f)  # 避免np.log(0)

    return np.log(f)


def main():
    samples = np.random.uniform(low=-1, high=1, size=(sample_rate * num_seconds,))
    print(samples.shape)

    frame_samples_0 = samples[:frame_length]
    frame_samples_1 = samples[1 * frame_shift : (frame_shift + frame_length)]
    frame_samples_2 = samples[2 * frame_shift : (2 * frame_shift + frame_length)]

    feature_frame_0 = compute_fbank(frame_samples_0)
    feature_frame_1 = compute_fbank(frame_samples_1)
    feature_frame_2 = compute_fbank(frame_samples_2)

    opts = knf.FbankOptions()
    opts.frame_opts.window_type = "hann"
    opts.mel_opts.num_bins = 23
    extractor = knf.OnlineFbank(opts)
    extractor.accept_waveform(sample_rate, samples.tolist())
    extractor.input_finished()

    # (16000 - 400)//160 + 1
    print("num_frames_ready", extractor.num_frames_ready)

    f0 = extractor.get_frame(0)
    f1 = extractor.get_frame(1)
    f2 = extractor.get_frame(2)

    print(np.abs(np.array(feature_frame_0) - np.array(f0)).max())
    print(np.abs(np.array(feature_frame_1) - np.array(f1)).max())
    print(np.abs(np.array(feature_frame_2) - np.array(f2)).max())


if __name__ == "__main__":
    np.random.seed(202250929)

    main()
