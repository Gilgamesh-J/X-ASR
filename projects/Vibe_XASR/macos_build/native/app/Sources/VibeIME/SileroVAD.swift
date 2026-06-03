import Foundation

/// Streaming VAD backed by sherpa-onnx's own silero VAD
/// (`SherpaOnnxVoiceActivityDetector`, configured with `silero_vad`).
///
/// This is a faithful port of the validated Python `_build_silero` + run-loop
/// recipe in vad_asr_demo/live_asr.py: feed 512-sample (32 ms @ 16 kHz) windows,
/// read the live speech state from `Detected()` (which already carries the
/// min-silence hysteresis), and drain the completed-segment queue every chunk so
/// the internal buffer can't grow unbounded during a long hold. We never read
/// the segment audio — the DictationEngine streams the ASR itself; the VAD here
/// is purely the speech/silence edge detector the engine's `isSpeech` expects.
///
/// The engine feeds exactly `windowSize == 512` samples per `accept`, matching
/// silero's fixed `window_size`, so no extra re-chunking is required.
final class SileroVAD: StreamingVAD {
    private let vad: SherpaOnnxVoiceActivityDetectorWrapper

    /// `modelPath` must point at a silero_vad.onnx. Returns nil if it's missing
    /// (so the caller can fall back to FireRedVAD rather than fatalError).
    init?(modelPath: String) {
        guard FileManager.default.fileExists(atPath: modelPath) else { return nil }
        // Match the Python demo defaults: window 512, threshold 0.5,
        // min_silence 0.5s, min_speech 0.2s. A 30 s buffer is plenty for a hold.
        let silero = sherpaOnnxSileroVadModelConfig(
            model: modelPath,
            threshold: 0.5,
            minSilenceDuration: 0.5,
            minSpeechDuration: 0.2,
            windowSize: 512,
            maxSpeechDuration: 10.0
        )
        var config = sherpaOnnxVadModelConfig(
            sileroVad: silero,
            sampleRate: 16000,
            numThreads: 1,
            provider: "cpu",
            debug: 0
        )
        self.vad = withUnsafePointer(to: &config) {
            SherpaOnnxVoiceActivityDetectorWrapper(config: $0, buffer_size_in_seconds: 30)
        }
    }

    func reset() {
        vad.reset()
        vad.clear()
    }

    func accept(int16 samples: [Int16]) {
        guard !samples.isEmpty else { return }
        // sherpa's VAD wants float [-1, 1].
        var f = [Float](repeating: 0, count: samples.count)
        for i in 0..<samples.count { f[i] = Float(samples[i]) / 32768.0 }
        vad.acceptWaveform(samples: f)
        // Drain completed segments so the buffer doesn't grow without bound
        // (silero in a live stream may not auto-pop). We only need the live
        // `Detected()` edge, so the segment audio is discarded.
        while !vad.isEmpty() { vad.pop() }
    }

    /// "Currently inside speech", with silero's built-in min-silence hysteresis.
    var isSpeech: Bool { vad.isSpeechDetected() }
}
