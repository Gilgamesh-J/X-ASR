import Foundation

/// Concrete VAD/ASR are provided by the firered C shim and sherpa-onnx (wired in
/// once the agents land). The engine orchestration below is a faithful Swift port
/// of the validated Python run() loop: VAD speech→silence edge endpointing with a
/// preroll buffer that recovers the sentence start.

protocol StreamingVAD: AnyObject {
    func reset()
    func accept(int16 samples: [Int16])
    var isSpeech: Bool { get }
}

protocol StreamingASR: AnyObject {
    func startSentence()                  // create a fresh recognizer stream
    func accept(_ samples16k: [Float])    // feed 16 kHz float [-1, 1]
    func partialText() -> String          // current decoded text
    func finalizeSentence() -> String     // pad tail + input-finished + decode + text, end stream
}

final class DictationEngine {
    private let vad: StreamingVAD
    private let asr: StreamingASR
    private let windowSize = 512                 // 32 ms @ 16 kHz
    private let prerollWindows: Int

    var onPartial: ((String) -> Void)?
    var onFinal: ((String) -> Void)?

    private var buffer: [Float] = []
    private var preroll: [[Float]] = []
    private var active = false
    /// 串行化引擎 + sherpa stream 的访问:feed/decode 跑在麦克风采集队列,而
    /// startSession/endSession 由主线程(begin/endDictation)调用。两者并发会在
    /// 解码进行中重置识别 stream → 野指针崩溃(EXC_BAD_ACCESS in beam-search Decode)。
    /// 锁住三个入口即可保证同一时刻只有一个线程在动引擎/stream。回调都是 async 派发,
    /// 不会在持锁期间重入,故无死锁风险。
    private let lock = NSLock()
    /// Push-to-talk: the whole hold is ONE utterance. When true, mid-hold VAD
    /// pauses do NOT finalize (which would chop the utterance into fragments,
    /// each getting its own spurious trailing punctuation). false = hands-free
    /// continuous mode that commits each sentence on the silence edge.
    /// Settable so the host can switch between push-to-talk (true) and the
    /// always-on OnCall / hands-free continuous mode (false) at runtime.
    var holdToTalk: Bool

    init(vad: StreamingVAD, asr: StreamingASR, prerollSec: Double = 1.0, holdToTalk: Bool = true) {
        self.vad = vad
        self.asr = asr
        self.holdToTalk = holdToTalk
        self.prerollWindows = max(1, Int(prerollSec * 16000 / Double(windowSize)))
    }

    /// Push-to-talk key down.
    func startSession() {
        lock.lock(); defer { lock.unlock() }
        active = false
        buffer.removeAll()
        preroll.removeAll()
        vad.reset()
        asr.startSentence()   // clear recognizer state so no carryover between holds
    }

    /// Feed 16 kHz float samples (called repeatedly while the key is held).
    func feed(_ samples: [Float]) {
        lock.lock(); defer { lock.unlock() }
        buffer.append(contentsOf: samples)
        while buffer.count >= windowSize {
            let w = Array(buffer.prefix(windowSize))
            buffer.removeFirst(windowSize)
            process(w)
        }
    }

    /// Push-to-talk key up: finalize any in-flight sentence.
    func endSession() {
        lock.lock(); defer { lock.unlock() }
        // Flush the trailing partial window (< windowSize samples) that never got
        // processed — otherwise the last few ms (a soft final syllable) are dropped.
        if active && !buffer.isEmpty { asr.accept(buffer) }
        if active { emitFinal() }
        buffer.removeAll()
        preroll.removeAll()
    }

    private func process(_ w: [Float]) {
        var i16 = [Int16](repeating: 0, count: w.count)
        for i in 0..<w.count {
            let v = Int(w[i] * 32767)
            i16[i] = Int16(max(-32768, min(32767, v)))
        }
        vad.accept(int16: i16)
        let speech = vad.isSpeech

        if speech && !active {                 // onset → open stream + replay preroll
            active = true
            asr.startSentence()
            for pw in preroll { asr.accept(pw) }
        }
        if active {                            // feed + refresh partial
            asr.accept(w)
            let p = asr.partialText()
            if !p.isEmpty { onPartial?(p) }
        }
        // Hands-free mode commits each sentence on the speech→silence edge.
        // Hold-to-talk keeps streaming one utterance until release (endSession).
        if active && !speech && !holdToTalk {
            emitFinal()
        }

        preroll.append(w)
        if preroll.count > prerollWindows { preroll.removeFirst() }
    }

    private func emitFinal() {
        let text = asr.finalizeSentence()
        active = false
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { onFinal?(text) }
    }
}
