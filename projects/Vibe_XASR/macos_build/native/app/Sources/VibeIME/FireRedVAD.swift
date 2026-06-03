import Foundation
import CFireRed

/// Streaming VAD backed by the FireRedVAD C/C++ shim (CFireRed).
///
/// Wraps the C handle (`FRVad*`): `frv_create(model_dir)` in init, drives it
/// with int16 chunks via `frv_accept_int16`, exposes the confirmed speech state
/// via `frv_is_speech`, and frees the handle in deinit.
///
/// `model_dir` must contain firered_vad.onnx + cmvn_means.bin + cmvn_istd.bin.
final class FireRedVAD: StreamingVAD {
    private let handle: OpaquePointer

    /// Returns nil if the model directory is missing / the model fails to load.
    init?(modelDir: String) {
        guard let h = frv_create(modelDir) else { return nil }
        self.handle = h
    }

    deinit {
        frv_free(handle)
    }

    func reset() {
        frv_reset(handle)
    }

    func accept(int16 samples: [Int16]) {
        guard !samples.isEmpty else { return }
        samples.withUnsafeBufferPointer { buf in
            frv_accept_int16(handle, buf.baseAddress, Int32(buf.count))
        }
    }

    var isSpeech: Bool {
        frv_is_speech(handle) != 0
    }
}
