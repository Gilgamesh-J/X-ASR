import Foundation
import VibeUI

/// Resolves model directories. In the assembled .app the bundled models live
/// under Contents/Resources/{asr,firered} (+ silero_vad.onnx); when running the
/// bare `swift build` executable (no bundle resources) we fall back to the known
/// source dirs so the headless launch can still load the engine.
///
/// Downloaded latency tiers live in Application Support so they survive app
/// updates and stay out of the (read-only, signed) bundle.
enum ModelPaths {

    // Source-tree fallbacks (used by the dev executable / headless verify).
    private static let srcAsr =
        "/path/to/xasr_workspace/vad_asr_demo/models/asr"
    private static let srcFired =
        "/path/to/xasr_workspace/xasr_macos_build/macos_build/models/firered"
    private static let srcSilero =
        "/path/to/xasr_workspace/vad_asr_demo/models/silero_vad.onnx"

    private static var resourcePath: String? { Bundle.main.resourcePath }

    /// The bundled tier (chunk-960ms ships in Contents/Resources/asr).
    static let bundledTier = "960"

    // MARK: Application Support

    /// ~/Library/Application Support/VibeXASR (created if absent).
    static func appSupportDir() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
        let dir = base.appendingPathComponent("VibeXASR", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Application Support/VibeXASR/models/chunk-<tier>ms — where downloaded
    /// tiers are cached.
    static func downloadedTierDir(_ tier: String) -> URL {
        appSupportDir()
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent("chunk-\(tier)ms", isDirectory: true)
    }

    /// Where the user's hotword list is written for the engine to load (one
    /// phrase per line). Lives in Application Support so it survives app updates.
    static func hotwordsFilePath() -> URL {
        appSupportDir().appendingPathComponent("hotwords.txt")
    }

    // MARK: ASR (tier-aware)

    /// Bundled ASR directory (encoder/decoder/joiner-960ms.onnx + tokens.txt).
    static func bundledAsrDir() -> String {
        if let res = resourcePath {
            let bundled = (res as NSString).appendingPathComponent("asr")
            if FileManager.default.fileExists(atPath: bundled + "/tokens.txt") {
                return bundled
            }
        }
        return srcAsr
    }

    /// Legacy entry point (defaults to the bundled 960 ms dir).
    static func asrDir() -> String { bundledAsrDir() }

    /// Resolve the ASR directory for a given tier:
    ///   * 960 → the bundled dir.
    ///   * others → the downloaded dir if present, else nil (must download).
    static func asrDir(forTier tier: String) -> String? {
        if tier == bundledTier { return bundledAsrDir() }
        let dir = downloadedTierDir(tier)
        return tierFilesPresent(dir.path, tier: tier) ? dir.path : nil
    }

    /// sentencepiece BPE vocab (bpe.vocab) used to tokenize English hotwords.
    /// Tier-independent (same tokenizer across chunk sizes), so always resolved
    /// from the bundled asr dir. Returns nil when absent → English hotwords are
    /// skipped (Chinese still works via cjkchar).
    static func bpeVocabPath() -> String? {
        let p = bundledAsrDir() + "/bpe.vocab"
        return FileManager.default.fileExists(atPath: p) ? p : nil
    }

    /// FireRedVAD model directory (firered_vad.onnx + cmvn_means/istd.bin).
    static func firedDir() -> String {
        if let res = resourcePath {
            let bundled = (res as NSString).appendingPathComponent("firered")
            if FileManager.default.fileExists(atPath: bundled + "/firered_vad.onnx") {
                return bundled
            }
        }
        return srcFired
    }

    /// 汉字→拼音 table for homophone correction (bundled at Resources/pinyin.txt).
    /// Returns nil when absent → the normalizer simply no-ops.
    static func pinyinTablePath() -> String? {
        if let res = resourcePath {
            let p = (res as NSString).appendingPathComponent("pinyin.txt")
            if FileManager.default.fileExists(atPath: p) { return p }
        }
        let dev = "/path/to/xasr_workspace/xasr_macos_build/macos_build/native/app/Resources/pinyin.txt"
        return FileManager.default.fileExists(atPath: dev) ? dev : nil
    }

    /// silero_vad.onnx path (bundled at Resources/silero_vad.onnx; dev fallback
    /// to the demo models dir). Returns the path even if absent — callers check.
    static func sileroModelPath() -> String {
        if let res = resourcePath {
            let bundled = (res as NSString).appendingPathComponent("silero_vad.onnx")
            if FileManager.default.fileExists(atPath: bundled) { return bundled }
        }
        return srcSilero
    }

    // MARK: presence checks

    /// All four ASR files present for a tier in `dir`?
    static func tierFilesPresent(_ dir: String, tier: String) -> Bool {
        let fm = FileManager.default
        return ["encoder-\(tier)ms.onnx", "decoder-\(tier)ms.onnx",
                "joiner-\(tier)ms.onnx", "tokens.txt"]
            .allSatisfy { fm.fileExists(atPath: dir + "/" + $0) }
    }

    /// All four bundled (960 ms) ASR files present?
    static func asrFilesPresent(_ dir: String) -> Bool {
        tierFilesPresent(dir, tier: bundledTier)
    }

    /// Is a tier available (bundled or already downloaded)?
    static func tierAvailable(_ tier: LatencyTier) -> Bool {
        asrDir(forTier: tier.token) != nil
    }
}
