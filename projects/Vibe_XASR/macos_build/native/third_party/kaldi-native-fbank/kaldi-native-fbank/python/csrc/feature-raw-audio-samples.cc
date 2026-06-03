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

#include "kaldi-native-fbank/csrc/feature-raw-audio-samples.h"

#include <string>

#include "kaldi-native-fbank/python/csrc/feature-raw-audio-samples.h"
#include "kaldi-native-fbank/python/csrc/utils.h"

namespace knf {

static void PybindRawAudioSamplesOptions(py::module &m) {  // NOLINT
  using PyClass = RawAudioSamplesOptions;
  py::class_<PyClass>(m, "RawAudioSamplesOptions")
      .def(py::init<>())
      .def_readwrite("frame_opts", &PyClass::frame_opts)
      .def("__str__",
           [](const PyClass &self) -> std::string { return self.ToString(); })
      .def("as_dict",
           [](const PyClass &self) -> py::dict { return AsDict(self); })
      .def_static("from_dict",
                  [](py::dict dict) -> PyClass {
                    return RawAudioSamplesOptionsFromDict(dict);
                  })
      .def(py::pickle(
          [](const PyClass &self) -> py::dict { return AsDict(self); },
          [](py::dict dict) -> PyClass {
            return RawAudioSamplesOptionsFromDict(dict);
          }));
}

void PybindFeatureRawAudioSamples(py::module &m) {  // NOLINT
  PybindRawAudioSamplesOptions(m);
}

}  // namespace knf
