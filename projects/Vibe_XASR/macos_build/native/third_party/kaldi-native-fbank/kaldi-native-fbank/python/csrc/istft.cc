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

#include "kaldi-native-fbank/python/csrc/istft.h"

#include <cstdint>
#include <string>
#include <vector>

#include "kaldi-native-fbank/csrc/istft.h"

namespace knf {

void PybindIStft(py::module *m) {
  using PyClass = IStft;
  py::class_<IStft>(*m, "IStft")
      .def(py::init<const StftConfig &>(), py::arg("config"))
      .def("compute", &PyClass::Compute, py::arg("stft_result"),
           py::call_guard<py::gil_scoped_release>())
      .def("__call__", &PyClass::Compute, py::arg("stft_result"),
           py::call_guard<py::gil_scoped_release>());
}

}  // namespace knf
