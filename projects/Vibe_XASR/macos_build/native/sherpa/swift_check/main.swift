import Foundation
let dir = "/path/to/xasr_workspace/vad_asr_demo/models/asr"
let transducer = sherpaOnnxOnlineTransducerModelConfig(
  encoder: dir + "/encoder-960ms.onnx",
  decoder: dir + "/decoder-960ms.onnx",
  joiner:  dir + "/joiner-960ms.onnx")
let modelConfig = sherpaOnnxOnlineModelConfig(
  tokens: dir + "/tokens.txt",
  transducer: transducer,
  numThreads: 2, provider: "cpu", modelType: "zipformer2")
let featConfig = sherpaOnnxFeatureConfig(sampleRate: 16000, featureDim: 80)
var cfg = sherpaOnnxOnlineRecognizerConfig(
  featConfig: featConfig, modelConfig: modelConfig,
  enableEndpoint: false, decodingMethod: "greedy_search")
let recognizer = SherpaOnnxRecognizer(config: &cfg)

// read int16 PCM -> Float [-1,1]
let path = "/path/to/xasr_workspace/xasr_macos_build/models/firered/mic_test.s16"
let data = FileManager.default.contents(atPath: path)!
let n = data.count / 2
var samples = [Float](repeating: 0, count: n)
data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
  let p = raw.bindMemory(to: Int16.self)
  for i in 0..<n { samples[i] = Float(p[i]) / 32768.0 }
}
recognizer.acceptWaveform(samples: samples, sampleRate: 16000)
while recognizer.isReady() { recognizer.decode() }
recognizer.acceptWaveform(samples: [Float](repeating: 0, count: 16000), sampleRate: 16000) // 1.0s tail
recognizer.inputFinished()
while recognizer.isReady() { recognizer.decode() }
print("SWIFT: " + recognizer.getResult().text)
