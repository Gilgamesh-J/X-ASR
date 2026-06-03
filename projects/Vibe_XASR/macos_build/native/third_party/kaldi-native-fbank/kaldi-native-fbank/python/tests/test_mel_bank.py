#!/usr/bin/env python3
#
# Copyright (c)  2025  Xiaomi Corporation (authors: Fangjun Kuang)


import kaldi_native_fbank as knf


def test():
    mel_opts = knf.MelBanksOptions()
    mel_opts.num_bins = 80

    frame_opts = knf.FrameExtractionOptions()
    frame_opts.window_type = "hann"
    mel_bank = knf.MelBanks(opts=mel_opts, frame_opts=frame_opts)
    print(mel_bank.get_matrix().shape)
    print(mel_bank.get_matrix()[:10, :20])


def main():
    test()


if __name__ == "__main__":
    main()
