import Foundation

/// Streaming ASR backed by the sherpa-onnx streaming zipformer2 transducer
/// (wraps `SherpaOnnxRecognizer`). Mirrors the verified native xasr_stream.cc
/// recipe exactly: model_type "zipformer2", greedy_search (or
/// modified_beam_search when hotwords are set), numThreads 2, provider "cpu",
/// enableEndpoint false; finalize by appending 1.0 s of zeros, inputFinished,
/// drain, getResult, reset.
///
/// `asrDir` must contain encoder/decoder/joiner-<tier>ms.onnx + tokens.txt.
/// `tier` is the streaming chunk size in ms ("160"/"480"/"960"/"1920"); the
/// bundled model is "960". The model files are named with the tier suffix.
///
/// Hotwords (contextual biasing): pass `hotwordsFile` (one phrase per line) to
/// bias decoding toward those words. sherpa only honours hotwords under
/// `modified_beam_search`, so we switch decoders only when a non-empty file is
/// present — otherwise the default path stays byte-for-byte the greedy recipe.
/// English hotwords need the model's BPE vocab (`bpeVocab`, i.e. bpe.vocab) to be
/// tokenized; Chinese works with cjkchar alone, so a missing vocab degrades to
/// Chinese-only rather than failing.
final class SherpaASR: StreamingASR {
    private let recognizer: SherpaOnnxRecognizer
    private let sampleRate = 16000

    init(asrDir: String, tier: String = "960",
         hotwordsFile: String? = nil, hotwordsScore: Float = 2.0,
         bpeVocab: String? = nil) {
        let encoder = asrDir + "/encoder-\(tier)ms.onnx"
        let decoder = asrDir + "/decoder-\(tier)ms.onnx"
        let joiner  = asrDir + "/joiner-\(tier)ms.onnx"
        let tokens  = asrDir + "/tokens.txt"

        // Only enable biasing (and thus beam search) when a non-empty hotwords
        // file actually exists, so users without hotwords keep the exact greedy
        // recipe (no latency/behaviour change).
        let fm = FileManager.default
        let hwFile = hotwordsFile.flatMap { fm.fileExists(atPath: $0) ? $0 : nil }
        let hasHotwords: Bool = {
            guard let p = hwFile,
                  let sz = (try? fm.attributesOfItem(atPath: p))?[.size] as? Int
            else { return false }
            return sz > 0
        }()
        // This model represents EVERY CJK char as its own ▁-prefixed BPE piece and
        // has no bare-char tokens, so sherpa's `cjkchar` lookup (bare char) misses
        // every Chinese hotword. We therefore encode hotwords via the `bpe` unit
        // with an augmented bpe.vocab (bare CJK chars added for BPE bootstrap), and
        // HotwordsStore space-separates CJK chars so each maps to its ▁X piece.
        // Without the vocab, fall back to cjkchar (no biasing on this model, but
        // harmless). modeling_unit/bpe_vocab only affect hotword encoding, never
        // the decode path — so this is inert when hotwords are off.
        let bpe = bpeVocab.flatMap { fm.fileExists(atPath: $0) ? $0 : nil } ?? ""
        let modelingUnit = (hasHotwords && !bpe.isEmpty) ? "bpe" : "cjkchar"

        let transducer = sherpaOnnxOnlineTransducerModelConfig(
            encoder: encoder,
            decoder: decoder,
            joiner: joiner
        )
        let modelConfig = sherpaOnnxOnlineModelConfig(
            tokens: tokens,
            transducer: transducer,
            numThreads: 2,
            provider: "cpu",
            debug: 0,
            modelType: "zipformer2",
            modelingUnit: modelingUnit,
            bpeVocab: hasHotwords ? bpe : ""
        )
        let featConfig = sherpaOnnxFeatureConfig(sampleRate: 16000, featureDim: 80)
        var config = sherpaOnnxOnlineRecognizerConfig(
            featConfig: featConfig,
            modelConfig: modelConfig,
            enableEndpoint: false,
            decodingMethod: hasHotwords ? "modified_beam_search" : "greedy_search",
            maxActivePaths: 4,
            hotwordsFile: hasHotwords ? (hwFile ?? "") : "",
            hotwordsScore: hotwordsScore
        )
        self.recognizer = SherpaOnnxRecognizer(config: &config)
    }

    /// Start a fresh sentence with a brand-new stream (Python parity — avoids the
    /// previous sentence's trailing punctuation leaking into this one).
    func startSentence() {
        recognizer.newStream()
    }

    // MARK: CJK de-spacing (port of the Python normalize_cjk)
    // sherpa's zipformer BPE inserts spaces between tokens; drop the spaces that
    // sit between two CJK glyphs/punct, and any space directly before ASCII punct.
    private static let cjkPunct = Set("，。！？；：、（）《》〈〉【】「」『』“”‘’")
    private static let asciiPunct = Set(",.!?;:%)]}")

    private static func isCJK(_ c: Character) -> Bool {
        guard c.unicodeScalars.count == 1, let v = c.unicodeScalars.first?.value else { return false }
        return (0x3400...0x4DBF).contains(v) || (0x4E00...0x9FFF).contains(v) || (0xF900...0xFAFF).contains(v)
    }
    private static func isCJKish(_ c: Character) -> Bool { isCJK(c) || cjkPunct.contains(c) }

    static func normalizeCJK(_ text: String) -> String {
        let chars = Array(text)
        var out: [Character] = []
        out.reserveCapacity(chars.count)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == " " {
                let prev = out.last
                var j = i + 1
                while j < chars.count && chars[j] == " " { j += 1 }   // next non-space
                let next: Character? = j < chars.count ? chars[j] : nil
                let dropAscii = next != nil && asciiPunct.contains(next!)
                let dropCJK = prev != nil && next != nil && isCJKish(prev!) && isCJKish(next!)
                if dropAscii || dropCJK { i += 1; continue }          // drop this space
            }
            out.append(c)
            i += 1
        }
        return String(out)
    }

    /// Feed a chunk of 16 kHz float [-1, 1] and drain any ready decode work so
    /// the partial text stays current.
    func accept(_ samples16k: [Float]) {
        recognizer.acceptWaveform(samples: samples16k, sampleRate: sampleRate)
        while recognizer.isReady() {
            recognizer.decode()
        }
    }

    /// Current decoded text (CJK de-spaced).
    func partialText() -> String {
        SherpaASR.normalizeCJK(recognizer.getResult().text)
    }

    /// Finalize: pad trailing zeros to flush the last zipformer2 chunk, signal
    /// input-finished, drain, read the final text, then reset for reuse.
    func finalizeSentence() -> String {
        // 1.5 s of zeros — more trailing context so a soft/short final word still
        // gets decoded (was 1.0 s; a quiet last syllable could get dropped).
        let tail = [Float](repeating: 0, count: sampleRate * 3 / 2)
        recognizer.acceptWaveform(samples: tail, sampleRate: sampleRate)
        recognizer.inputFinished()
        while recognizer.isReady() {
            recognizer.decode()
        }
        let text = SherpaASR.normalizeCJK(recognizer.getResult().text)
        recognizer.newStream()
        // The streaming model only emits a sentence's closing punctuation when it
        // hears the NEXT sentence start, so the FINAL sentence never gets one. Add a
        // sensible closing mark if it's missing.
        return SherpaASR.ensureFinalPunct(text)
    }

    /// Append a closing 。 (CJK) or . (otherwise) when the final text doesn't already
    /// end in punctuation.
    static func ensureFinalPunct(_ text: String) -> String {
        guard let last = text.last else { return text }
        if cjkPunct.contains(last) || asciiPunct.contains(last) { return text }
        return text + (isCJK(last) ? "。" : ".")
    }
}
