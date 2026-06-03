import Foundation
import VibeUI

/// Local, on-device dictation history.
///
/// Every dictation final is appended to
/// `~/Library/Application Support/VibeXASR/history.json` — a JSON array of
/// `{text, date}` (date = ISO-8601). File writes go through a private serial
/// `DispatchQueue` so concurrent appends can't corrupt the file; reads tolerate
/// a missing or corrupt file (returning an empty list). Nothing here ever
/// touches the network — the data stays on this device.
///
/// The in-memory `entries` (newest-first) is `@Published` so the History window
/// updates live. `HistoryItem` is the VibeUI-facing row type so the window can
/// render without importing this target.
@MainActor
final class HistoryStore: ObservableObject, HistoryBridge {

    static let shared = HistoryStore()

    /// Newest-first, for display.
    @Published private(set) var entries: [HistoryItem] = []

    /// Lifetime cumulative character count dictated. Persisted separately (in
    /// UserDefaults) so it SURVIVES clearing the history list — it only ever grows.
    @Published private(set) var lifetimeChars: Int = UserDefaults.standard.integer(forKey: lifetimeCharsKey) {
        didSet { UserDefaults.standard.set(lifetimeChars, forKey: Self.lifetimeCharsKey) }
    }
    private static let lifetimeCharsKey = "historyLifetimeChars"

    private let queue = DispatchQueue(label: "com.xasr.vibexasr.history")
    private let fileURL: URL

    private struct Record: Codable {
        var id: String?     // optional for old files; persisted so ids stay stable across reloads
        var text: String
        var date: Date
        var mode: String?   // "manual" | "oncall"; optional for old files
        var tags: [String]? // optional for old files
        var title: String?  // note title (整理成笔记); nil for normal entries
    }

    /// HistoryItem → on-disk Record (used by persist + export).
    private func record(_ e: HistoryItem) -> Record {
        Record(id: e.id.uuidString, text: e.text, date: e.date, mode: e.mode,
               tags: e.tags.isEmpty ? nil : e.tags, title: e.title)
    }

    init() {
        self.fileURL = ModelPaths.appSupportDir().appendingPathComponent("history.json")
        load()
    }

    // MARK: HistoryBridge (read API for the window)

    var historyItems: [HistoryItem] { entries }

    /// Append a final (called on each engine.onFinal). Ignores blank text.
    /// Seconds an ephemeral (history-disabled) record survives before self-destruct.
    static let ephemeralTTL: TimeInterval = 60

    /// Append a final. When `ephemeral` (history saving is OFF) the entry is kept in
    /// memory only for `ephemeralTTL` seconds (shown with a countdown) then removed,
    /// and never written to disk — a grace buffer so a long unsaved dictation isn't
    /// lost the instant it ends.
    func append(_ text: String, mode: String = "manual", ephemeral: Bool = false) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let expires = ephemeral ? Date().addingTimeInterval(Self.ephemeralTTL) : nil
        // Store the trimmed text — stray leading whitespace (common in ASR output)
        // would indent the row vs its timestamp.
        let item = HistoryItem(id: UUID(), text: trimmed, date: Date(), mode: mode, expiresAt: expires)
        entries.insert(item, at: 0)               // newest first in memory
        lifetimeChars += trimmed.count            // cumulative; survives clearing
        if let expires {
            let id = item.id
            let delay = expires.timeIntervalSinceNow
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0, delay)) { [weak self] in
                self?.entries.removeAll { $0.id == id }   // self-destruct (never persisted)
            }
        } else {
            persistAsync()
        }
    }

    /// Delete a single entry by id.
    func delete(id: UUID) {
        entries.removeAll { $0.id == id }
        persistAsync()
    }

    /// Edit an entry's text in place (issue #6). Keeps id + date; does NOT change
    /// lifetimeChars (which counts what was dictated, not the current edited text).
    func update(id: UUID, text: String) {
        let cur = entries.first { $0.id == id }
        update(id: id, text: text, title: cur?.title, tags: cur?.tags ?? [])
    }

    /// Rich edit (inline editor): text + note title + tags. Keeps id + date + mode.
    func update(id: UUID, text: String, title: String?, tags: [String]) {
        guard let idx = entries.firstIndex(where: { $0.id == id }) else { return }
        let old = entries[idx]
        entries[idx] = HistoryItem(id: old.id, text: text, date: old.date, mode: old.mode,
                                   expiresAt: old.expiresAt, tags: tags, title: title)
        persistAsync()
    }

    /// Merge entries → one. Ascending-date join; newest entry is the anchor (kept),
    /// others removed. asNote → newline-join + note title; else direct concat. Tags
    /// unioned; mode = "oncall" iff every merged entry was oncall.
    func merge(ids: [UUID], asNote: Bool, title: String?) {
        let set = Set(ids)
        // entries is newest-first → index 0 is the newest (top of the list).
        let order = Dictionary(entries.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
        // Merge in DISPLAY order: the entry shown ABOVE (newer) comes first, the one
        // BELOW (older) after — matching what the user sees top→bottom. Stable
        // tiebreak on list position so same-timestamp fragments never scramble.
        let chosen = entries.filter { set.contains($0.id) }.sorted { a, b in
            a.date != b.date ? a.date > b.date : (order[a.id] ?? 0) < (order[b.id] ?? 0)
        }
        guard chosen.count >= (asNote ? 1 : 2) else { return }
        let text = chosen.map(\.text).joined(separator: asNote ? "\n" : "")
        guard let anchor = chosen.first else { return }   // top (newest) entry = anchor → "合并到上面的时间"
        var mergedTags: [String] = []
        for e in chosen { for t in e.tags where !mergedTags.contains(t) { mergedTags.append(t) } }
        let allOnCall = chosen.allSatisfy { $0.mode == "oncall" }
        entries = entries.compactMap { e in
            if e.id == anchor.id {
                return HistoryItem(id: e.id, text: text, date: e.date,
                                   mode: allOnCall ? "oncall" : "manual",
                                   expiresAt: e.expiresAt, tags: mergedTags,
                                   title: asNote ? (title ?? "整理笔记") : nil)
            }
            return set.contains(e.id) ? nil : e
        }
        persistAsync()
    }

    /// Union `tag` into each id.
    func applyTag(ids: [UUID], tag: String) {
        let set = Set(ids)
        entries = entries.map { e in
            guard set.contains(e.id), !e.tags.contains(tag) else { return e }
            return HistoryItem(id: e.id, text: e.text, date: e.date, mode: e.mode,
                               expiresAt: e.expiresAt, tags: e.tags + [tag], title: e.title)
        }
        persistAsync()
    }

    /// Replace an entry's tags wholesale.
    func setTags(id: UUID, tags: [String]) {
        guard let idx = entries.firstIndex(where: { $0.id == id }) else { return }
        let old = entries[idx]
        entries[idx] = HistoryItem(id: old.id, text: old.text, date: old.date, mode: old.mode,
                                   expiresAt: old.expiresAt, tags: tags, title: old.title)
        persistAsync()
    }

    /// Insert a blank manual entry at now; returns its id for immediate editing.
    @discardableResult func addEntry() -> UUID {
        let item = HistoryItem(id: UUID(), text: "", date: Date(), mode: "manual")
        entries.insert(item, at: 0)
        persistAsync()
        return item.id
    }

    /// Replace the whole list (undo restore). lifetimeChars is unaffected.
    func replaceAll(_ items: [HistoryItem]) {
        entries = items
        persistAsync()
    }

    /// Clear all history.
    func clearAll() {
        entries.removeAll()
        lifetimeChars = 0          // clearing records also resets the cumulative stats
        persistAsync()
    }

    // MARK: export (issue #5)

    /// JSON representation of all history (chronological, oldest-first), ready to
    /// write to a user-chosen file via NSSavePanel. The NSSavePanel itself lives in
    /// the AppKit-capable HistoryView.
    func exportJSONData() -> Data {
        let records = entries.reversed().filter { $0.expiresAt == nil }.map(record)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? encoder.encode(records)) ?? Data("[]".utf8)
    }

    /// Plain-text representation: one entry per block, "<ISO date>\t<text>"
    /// chronological (oldest-first).
    func exportPlainText() -> String {
        let iso = ISO8601DateFormatter()
        return entries.reversed()
            .map { "\(iso.string(from: $0.date))\t\($0.text)" }
            .joined(separator: "\n")
    }

    // MARK: persistence

    /// Load synchronously at startup; tolerate missing/corrupt file.
    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let records = try? decoder.decode([Record].self, from: data) else {
            // Corrupt file — start fresh (don't crash). The next write overwrites it.
            return
        }
        // Stored oldest-first; present newest-first.
        entries = records.reversed().map {
            HistoryItem(id: $0.id.flatMap(UUID.init) ?? UUID(),
                        text: $0.text, date: $0.date, mode: $0.mode ?? "manual",
                        tags: $0.tags ?? [], title: $0.title)
        }
    }

    /// Snapshot the current entries and write them off the main thread.
    private func persistAsync() {
        // Store oldest-first (chronological) so external readers see natural order.
        let records = entries.reversed().filter { $0.expiresAt == nil }.map(record)
        let url = fileURL
        queue.async {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted]
            guard let data = try? encoder.encode(records) else { return }
            // Atomic write so a crash mid-write can't truncate the file.
            try? data.write(to: url, options: .atomic)
        }
    }
}
