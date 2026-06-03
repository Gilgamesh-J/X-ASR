/**
 * Copyright (c)  2025  Xiaomi Corporation (authors: Fangjun Kuang)
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

#include "kaldi-native-fbank/csrc/stft.h"

#include <cstdint>
#include <string>
#include <vector>

#include "kaldi-native-fbank/python/csrc/stft.h"

namespace knf {

void PybindStftConfig(py::module *m) {
  using PyClass = StftConfig;
  py::class_<PyClass>(*m, "StftConfig")
      .def(py::init<int32_t, int32_t, int32_t, const std::string &, bool,
                    const std::string &, bool, const std::vector<float> &>(),
           py::arg("n_fft"), py::arg("hop_length"), py::arg("win_length"),
           py::arg("window_type") = "", py::arg("center") = true,
           py::arg("pad_mode") = "reflect", py::arg("normalized") = false,
           py::arg("window") = std::vector<float>{})
      .def_readwrite("n_fft", &PyClass::n_fft)
      .def_readwrite("hop_length", &PyClass::hop_length)
      .def_readwrite("win_length", &PyClass::win_length)
      .def_readwrite("n_fft", &PyClass::n_fft)
      .def_readwrite("window_type", &PyClass::window_type)
      .def_readwrite("center", &PyClass::center)
      .def_readwrite("pad_mode", &PyClass::pad_mode)
      .def_readwrite("normalized", &PyClass::normalized)
      .def("__str__", &PyClass::ToString);
}

void PybindStftResult(py::module *m) {
  using PyClass = StftResult;
  py::class_<PyClass>(*m, "StftResult")
      .def(py::init<const std::vector<float> &, const std::vector<float> &,
                    int32_t>(),
           py::arg("real"), py::arg("imag"), py::arg("num_frames"))
      .def_property_readonly("real",
                             [](const PyClass &self) { return self.real; })
      .def_property_readonly("imag",
                             [](const PyClass &self) { return self.imag; })
      .def_property_readonly(
          "num_frames", [](const PyClass &self) { return self.num_frames; });
}

void PybindStft(py::module *m) {
  PybindStftConfig(m);
  PybindStftResult(m);
  using PyClass = Stft;
  py::class_<Stft>(*m, "Stft")
      .def(py::init<const StftConfig &>(), py::arg("config"))
      .def(
          "compute",
          [](Stft &self, const std::vector<float> &d) -> StftResult {
            return self.Compute(d.data(), d.size());
          },
          py::arg("input"), py::call_guard<py::gil_scoped_release>())

      .def(
          "__call__",
          [](Stft &self, const std::vector<float> &d) -> StftResult {
            return self.Compute(d.data(), d.size());
          },
          py::arg("input"), py::call_guard<py::gil_scoped_release>());
}

}  // namespace knf
