// ============================================================
//  Vibe XASR — Host bridges for the VibeUI windows
//
//  The VibeUI library stays framework-light (SwiftUI only). The host app
//  (VibeIME) implements these protocols to provide real model-management,
//  history and pad behaviour to the Settings / History / Pad surfaces. Concrete
//  stores live in the app target; these are the read/write seams.
// ============================================================

import Foundation

// MARK: - Model management (Model tab)

/// Live model-management state for the latency-tier rows. The host's
/// ModelDownloader conforms to this; the Model tab observes it (the host passes
/// an ObservableObject so SwiftUI refreshes on download progress).
@MainActor
public protocol ModelManagerBridge: AnyObject {
    func isTierDownloaded(_ tier: LatencyTier) -> Bool
    func isTierBundled(_ tier: LatencyTier) -> Bool
    /// 0...1 while downloading, nil otherwise.
    func downloadProgress(_ tier: LatencyTier) -> Double?
    func didTierFail(_ tier: LatencyTier) -> Bool

    func startDownload(_ tier: LatencyTier)
    func cancelDownload(_ tier: LatencyTier)
    @discardableResult func deleteTier(_ tier: LatencyTier) -> Bool

    // ----- AI 润色(本地 Beta)GGUF —— 在线按需下载 -----
    /// 模型是否已就绪(本地存在)。
    func refinerAvailable() -> Bool
    /// 0...1 下载中;nil 表示未在下载。
    func refinerDownloadProgress() -> Double?
    /// 上一次下载是否失败(可重试)。
    func refinerDownloadFailed() -> Bool
    /// 触发在线下载(缺模型时);已就绪 / 正在下载则 no-op。
    func startRefinerDownload()
    /// 删除已下载的模型(释放空间 / 重新下载)。返回删除后是否确已不存在。
    @discardableResult func deleteRefiner() -> Bool
}

/// 默认实现:让预览 / 旧 host 在不实现 refiner 下载时仍能编译(全部惰性)。
public extension ModelManagerBridge {
    func refinerAvailable() -> Bool { false }
    func refinerDownloadProgress() -> Double? { nil }
    func refinerDownloadFailed() -> Bool { false }
    func startRefinerDownload() {}
    @discardableResult func deleteRefiner() -> Bool { false }
}

// MARK: - History window

/// One persisted dictation final.
public struct HistoryItem: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let text: String
    public let date: Date
    /// "manual" (push-to-talk) or "oncall" (always-on standby). Used to badge and
    /// optionally hide OnCall entries in the list + export.
    public let mode: String
    /// When set, this is an EPHEMERAL record (history saving was off) that self-
    /// destructs at this instant; the row shows a live countdown. nil = permanent.
    public let expiresAt: Date?
    /// Topic tags (history workspace). Empty = untagged.
    public let tags: [String]
    /// Non-nil when this entry is a "note" (整理成笔记) — rendered with an accent title.
    public let title: String?
    public init(id: UUID, text: String, date: Date, mode: String = "manual",
                expiresAt: Date? = nil, tags: [String] = [], title: String? = nil) {
        self.id = id; self.text = text; self.date = date; self.mode = mode
        self.expiresAt = expiresAt; self.tags = tags; self.title = title
    }
}

/// Read/mutate the local dictation history. The host's HistoryStore conforms.
@MainActor
public protocol HistoryBridge: AnyObject {
    var historyItems: [HistoryItem] { get }
    func delete(id: UUID)
    func clearAll()

    /// Cumulative characters ever dictated. Persists across clearing the list
    /// (issue #9). Default 0 so previews / older hosts compile.
    var lifetimeChars: Int { get }

    /// Edit an entry in place (issue #6). Default no-op for previews.
    func update(id: UUID, text: String)

    // ----- History workspace mutations (default no-op so previews compile) -----
    /// Rich edit: text + note title + tags in one shot (inline editor).
    func update(id: UUID, text: String, title: String?, tags: [String])
    /// Merge entries into one. Ascending-date join; the NEWEST entry is the anchor
    /// (kept), others removed. asNote → newline-joined with `title`; else direct
    /// concat. Tags unioned; mode = "oncall" iff every merged entry was oncall.
    func merge(ids: [UUID], asNote: Bool, title: String?)
    /// Union `tag` into each id.
    func applyTag(ids: [UUID], tag: String)
    /// Replace an entry's tags.
    func setTags(id: UUID, tags: [String])
    /// Insert a blank manual entry at now; returns its id for immediate editing.
    @discardableResult func addEntry() -> UUID
    /// Replace the whole list (undo restore).
    func replaceAll(_ items: [HistoryItem])

    /// Serialize ALL history for "export all" (issue #5). The view writes the
    /// returned data via NSSavePanel. Defaults produce empty payloads in previews.
    func exportJSONData() -> Data
    func exportPlainText() -> String
}

public extension HistoryBridge {
    var lifetimeChars: Int { 0 }
    func update(id: UUID, text: String) {}
    func update(id: UUID, text: String, title: String?, tags: [String]) {}
    func merge(ids: [UUID], asNote: Bool, title: String?) {}
    func applyTag(ids: [UUID], tag: String) {}
    func setTags(id: UUID, tags: [String]) {}
    @discardableResult func addEntry() -> UUID { UUID() }
    func replaceAll(_ items: [HistoryItem]) {}
    func exportJSONData() -> Data { Data("[]".utf8) }
    func exportPlainText() -> String { "" }
}

// MARK: - Pad window

/// Two-way access to the built-in Pad text + helpers. The host's PadStore
/// conforms (an ObservableObject so the editor stays in sync with appends).
@MainActor
public protocol PadBridge: AnyObject {
    var padText: String { get set }
    func clear()
}
