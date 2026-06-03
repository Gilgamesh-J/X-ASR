/**
 * Copyright      2022  Xiaomi Corporation (authors: Fangjun Kuang)
 *
 * See LICENSE for clarification regarding multiple authors
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#include <cstdint>
#include <vector>

#include "gtest/gtest.h"
#include "kaldi-native-fbank/csrc/rfft.h"

namespace knf {

#if 0
>>> import torch
>>> a = torch.tensor([1., -1, 3, 8, 20, 6, 0, 2])
>>> torch.fft.rfft(a)
tensor([ 39.0000+0.0000j, -28.1924-2.2929j,  18.0000+5.0000j,  -9.8076+3.7071j,
          9.0000+0.0000j])
#endif

TEST(PowerOfTwo, TestRfft) {
  knf::Rfft fft(8);
  std::vector<float> original = {1, -1, 3, 8, 20, 6, 0, 2};

  std::vector<float> d = original;
  fft.Compute(d.data());

  EXPECT_EQ(d[0], 39);
  EXPECT_EQ(d[1], 9);

  EXPECT_NEAR(d[2], -28.1924, 1e-3);
  EXPECT_NEAR(d[3], -2.2929, 1e-3);

  EXPECT_NEAR(d[4], 18, 1e-3);
  EXPECT_NEAR(d[5], 5, 1e-3);

  EXPECT_NEAR(d[6], -9.8076, 1e-3);
  EXPECT_NEAR(d[7], 3.7071, 1e-3);

  knf::Rfft ifft(8, true);
  ifft.Compute(d.data());

  for (int32_t i = 0; i < d.size(); ++i) {
    d[i] /= d.size();  // we need to rescale it by 1/n
    EXPECT_EQ(d[i], original[i]);
  }
}

#if 0
>>> import torch
>>> a = torch.tensor([1., -1, 3, 8, 20, 6, 0, 2, 9, 5])
>>> torch.fft.rfft(a)
tensor([ 53.0000+0.0000j, -17.3262-8.2290j,  -3.3820+31.7809j,
         -1.6738-13.3148j,  -5.6180+3.8697j,  13.0000+0.0000j])
#endif
TEST(NotPowerOfTwo, TestRfft) {
  knf::Rfft fft(10);
  std::vector<float> original = {1, -1, 3, 8, 20, 6, 0, 2, 9, 5};

  std::vector<float> d = original;
  fft.Compute(d.data());

  EXPECT_EQ(d[0], 53);
  EXPECT_EQ(d[1], 13);

  EXPECT_NEAR(d[2], -17.3262, 1e-3);
  EXPECT_NEAR(d[3], -8.2290, 1e-3);

  EXPECT_NEAR(d[4], -3.3820, 1e-3);
  EXPECT_NEAR(d[5], 31.7809, 1e-3);

  EXPECT_NEAR(d[6], -1.6738, 1e-3);
  EXPECT_NEAR(d[7], -13.3148, 1e-3);

  EXPECT_NEAR(d[8], -5.6180, 1e-3);
  EXPECT_NEAR(d[9], 3.8697, 1e-3);

  knf::Rfft ifft(10, true);
  ifft.Compute(d.data());

  for (int32_t i = 0; i < d.size(); ++i) {
    d[i] /= d.size();  // we need to rescale it by 1/n
    EXPECT_NEAR(d[i], original[i], 1e-5);
  }
}

}  // namespace knf
