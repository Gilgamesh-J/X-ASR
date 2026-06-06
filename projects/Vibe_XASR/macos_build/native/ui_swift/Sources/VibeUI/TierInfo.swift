// ============================================================
//  Vibe XASR — Latency-tier metadata (shared by UI + host)
//
//  The streaming chunk model comes in four sizes. Only chunk-960ms ships in the
//  bundle; the others download on demand from the chosen mirror (ModelScope by
//  default, or HuggingFace) — see SettingsView's source picker. This file is the
//  single source of truth for the tier set, their L10n keys and approximate
//  download size — referenced by both the SettingsView picker and the host's
//  ModelDownloader.
// ============================================================

import Foundation

/// A streaming latency tier (the chunk model size, in milliseconds).
public enum LatencyTier: Int, CaseIterable, Identifiable, Sendable {
    case ms160 = 160
    case ms480 = 480
    case ms960 = 960
    case ms1920 = 1920

    public var id: Int { rawValue }

    /// The on-disk / HF directory token, e.g. "960" → files named *-960ms.onnx.
    public var token: String { String(rawValue) }

    /// L10n key for the short name ("960 ms").
    public var nameKey: String { "model.tier.\(rawValue).name" }
    /// L10n key for the one-line scenario description.
    public var sceneKey: String { "model.tier.\(rawValue).scene" }

    /// Only chunk-960ms ships inside the .app bundle.
    public var isBundled: Bool { self == .ms960 }

    /// Rough per-tier download size shown in the UI. Full-precision loose files
    /// (ModelScope / HuggingFace) — encoder dominates, ~615 MB.
    public var approxSize: String { "~615 MB" }
    /// CDN 加速线路 / 内置:int8 量化归档的下载体积(每档 ~130 MB)。
    public var approxSizeQuantized: String { "~130 MB" }

    public static let `default`: LatencyTier = .ms960
}
