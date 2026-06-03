import AVFoundation
import AudioToolbox
import CoreMedia

/// Input-only microphone capture via **AVCaptureSession**, delivering 16 kHz mono
/// float32 samples.
///
/// We deliberately do NOT use AVAudioEngine: its I/O cycle is coupled to the
/// default OUTPUT device. When that output is a Bluetooth headset, macOS flips it
/// A2DP→HFP the instant any mic goes live, and the churn wedges AVAudioEngine's
/// input tap after 1–2 buffers (capture dies silently). AVCaptureSession is
/// input-only — no output node to disrupt — so capture survives the BT flip.
final class Mic: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    private var session: AVCaptureSession?
    private let sbQueue = DispatchQueue(label: "com.xasr.vibe.mic.capture")
    private var converter: AVAudioConverter?
    private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                       sampleRate: 16000, channels: 1, interleaved: false)!
    /// Called on the capture queue with a chunk of 16 kHz mono samples.
    var onSamples: (([Float]) -> Void)?
    /// Preferred input device UID ("" / nil = system default). Applied at start().
    var preferredDeviceUID: String?

    func start() throws {
        stop()
        guard let device = chooseDevice() else {
            throw NSError(domain: "Mic", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "无可用麦克风 / no input device"])
        }
        let input = try AVCaptureDeviceInput(device: device)
        let output = AVCaptureAudioDataOutput()
        output.setSampleBufferDelegate(self, queue: sbQueue)

        let session = AVCaptureSession()
        session.beginConfiguration()
        guard session.canAddInput(input) else {
            session.commitConfiguration()
            throw NSError(domain: "Mic", code: 2, userInfo: [NSLocalizedDescriptionKey: "无法添加麦克风输入"])
        }
        session.addInput(input)
        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            throw NSError(domain: "Mic", code: 3, userInfo: [NSLocalizedDescriptionKey: "无法添加音频输出"])
        }
        session.addOutput(output)
        session.commitConfiguration()

        converter = nil
        self.session = session
        session.startRunning()
    }

    func stop() {
        guard let session else { converter = nil; return }
        session.stopRunning()
        // Drain any in-flight sample-buffer callback before returning. stopRunning()
        // doesn't flush buffers already dispatched to sbQueue, so without this the
        // capture queue could still be inside the recognizer's decode() while the
        // caller finalizes the same recognizer on the main thread — concurrent
        // sherpa-onnx decode = EXC_BAD_ACCESS. A barrier on sbQueue serializes them.
        // (Safe from the main thread; onSamples only ever hops to main via async.)
        sbQueue.sync { }
        self.session = nil
        converter = nil
    }

    /// Resolve the chosen input device. Matches the persisted CoreAudio UID against
    /// AVCaptureDevice uniqueIDs; falls back to the system default audio device.
    private func chooseDevice() -> AVCaptureDevice? {
        guard let uid = preferredDeviceUID, !uid.isEmpty else {
            return AVCaptureDevice.default(for: .audio)
        }
        if let d = AVCaptureDevice(uniqueID: uid) { return d }
        let found = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio, position: .unspecified).devices
        return found.first { $0.uniqueID == uid } ?? AVCaptureDevice.default(for: .audio)
    }

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let fmtDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmtDesc),
              let inFormat = AVAudioFormat(streamDescription: asbd) else { return }
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frames > 0,
              let pcm = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: frames) else { return }
        pcm.frameLength = frames
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(
                sampleBuffer, at: 0, frameCount: Int32(frames),
                into: pcm.mutableAudioBufferList) == noErr else { return }

        if converter == nil || converter?.inputFormat != pcm.format {
            converter = AVAudioConverter(from: pcm.format, to: target)
        }
        guard let converter else { return }
        let ratio = target.sampleRate / pcm.format.sampleRate
        let cap = AVAudioFrameCount(Double(pcm.frameLength) * ratio + 32)
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: cap) else { return }
        var err: NSError?
        var supplied = false
        let status = converter.convert(to: out, error: &err) { _, outStatus in
            if supplied { outStatus.pointee = .noDataNow; return nil }
            supplied = true; outStatus.pointee = .haveData; return pcm
        }
        guard status == .haveData || status == .inputRanDry,
              let ch = out.floatChannelData, out.frameLength > 0 else { return }
        onSamples?(Array(UnsafeBufferPointer(start: ch[0], count: Int(out.frameLength))))
    }
}
