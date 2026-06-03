/**
 * Copyright (c)  2022  Xiaomi Corporation (authors: Fangjun Kuang)
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

#include "kaldi-native-fbank/python/csrc/mel-computations.h"

#include <algorithm>
#include <string>

#include "kaldi-native-fbank/csrc/mel-computations.h"
#include "kaldi-native-fbank/python/csrc/utils.h"

#define C_CONTIGUOUS py::detail::npy_api::constants::NPY_ARRAY_C_CONTIGUOUS_

namespace knf {

static void PybindMelBanksOptions(py::module &m) {  // NOLINT
  using PyClass = MelBanksOptions;
  py::class_<PyClass>(m, "MelBanksOptions")
      .def(py::init<>())
      .def_readwrite("num_bins", &PyClass::num_bins)
      .def_readwrite("low_freq", &PyClass::low_freq)
      .def_readwrite("high_freq", &PyClass::high_freq)
      .def_readwrite("vtln_low", &PyClass::vtln_low)
      .def_readwrite("vtln_high", &PyClass::vtln_high)
      .def_readwrite("debug_mel", &PyClass::debug_mel)
      .def_readwrite("htk_mode", &PyClass::htk_mode)
      .def_readwrite("is_librosa", &PyClass::is_librosa)
      .def_readwrite("norm", &PyClass::norm)
      .def_readwrite("use_slaney_mel_scale", &PyClass::use_slaney_mel_scale)
      .def_readwrite("floor_to_int_bin", &PyClass::floor_to_int_bin)
      .def("__str__",
           [](const PyClass &self) -> std::string { return self.ToString(); })
      .def("as_dict",
           [](const PyClass &self) -> py::dict { return AsDict(self); })
      .def_static("from_dict",
                  [](py::dict dict) -> PyClass {
                    return MelBanksOptionsFromDict(dict);
                  })
      .def(py::pickle(
          [](const PyClass &self) -> py::dict { return AsDict(self); },
          [](py::dict dict) -> PyClass {
            return MelBanksOptionsFromDict(dict);
          }));
}

void PybindMelComputations(py::module &m) {  // NOLINT
  PybindMelBanksOptions(m);
  using PyClass = MelBanks;
  py::class_<PyClass>(m, "MelBanks")
      .def(py::init<const MelBanksOptions &, const FrameExtractionOptions &,
                    float>(),
           py::arg("opts") = MelBanksOptions{},
           py::arg("frame_opts") = FrameExtractionOptions{},
           py::arg("vtln_warp_factor") = 1.0,
           py::call_guard<py::gil_scoped_release>())
      .def("get_matrix",
           [](const PyClass &self) -> py::array_t<float> {
             std::vector<float> matrix = self.GetMatrix();
             int32_t num_rows = self.NumBins();
             int32_t num_cols = matrix.size() / num_rows;

             py::array_t<float> ans({num_rows, num_cols});
             py::buffer_info buf = ans.request();
             auto p = static_cast<float *>(buf.ptr);
             std::copy(matrix.begin(), matrix.end(), p);
             return ans;
           })
      .def(
          "compute",
          [](const PyClass &self, const py::array_t<float> &fft_energies) {
            if (!(C_CONTIGUOUS == (fft_energies.flags() & C_CONTIGUOUS))) {
              throw py::value_error(
                  "input fft_energies should be contiguous. Please use "
                  "np.ascontiguousarray(fft_energies)");
            }

            int num_dim = fft_energies.ndim();
            if (num_dim != 1) {
              std::ostringstream os;
              os << "Expect an array of 1 dimension (num_fft_bins/2+1,)"
                    "Given dim: "
                 << num_dim << "\n";
              throw py::value_error(os.str());
            }

            py::array_t<float> ans(self.NumBins());

            py::buffer_info buf = ans.request();
            auto p = static_cast<float *>(buf.ptr);
            self.Compute(fft_energies.data(), p);

            return ans;
          },
          py::arg("fft_energies"))
      .def_property_readonly("dim", &PyClass::NumBins)
      .def_static("inverse_mel_scale", &PyClass::InverseMelScale,
                  py::arg("mel"))
      .def_static("mel_scale", &PyClass::MelScale, py::arg("hz"))
      .def_static("inverse_mel_scale_slaney", &PyClass::InverseMelScaleSlaney,
                  py::arg("mel"))
      .def_static("mel_scale_slaney", &PyClass::MelScaleSlaney, py::arg("hz"))

      ;
}

}  // namespace knf
