// ============================================================
//  Vibe XASR — History workspace state model
//
//  Holds the workspace's view + selection + edit + filter state and the undo
//  stack, and performs all mutations THROUGH the HistoryBridge (the host's
//  HistoryStore is the single source of truth for entries). Derivations
//  (groups / flatIds / stats) are computed in the view from `store.historyItems`
//  + this model's filter state; the view passes current `entries` / `flatIds`
//  into the methods that need them so the model needn't observe the store.
// ============================================================

import SwiftUI
import AppKit

enum WorkspacePane { case list, calendar }

@MainActor
final class HistoryWorkspaceModel: ObservableObject {

    // selection / editing
    @Published var selection: Set<UUID> = []
    @Published var editingID: UUID? = nil
    @Published var draftText: String = ""
    @Published var draftTitle: String? = nil
    @Published var draftTags: [String] = []
    @Published var focusIdx: Int = -1

    // filters / view
    @Published var query: String = ""
    @Published var selectedDay: String? = nil
    @Published var tagFilter: String? = nil
    @Published var aggregate: Bool = true
    @Published var aggMode: AggMode = .pause
    @Published var gapMin: Int = 2
    @Published var targetChars: Int = 120
    @Published var aggOpen: Bool = false
    @Published var pane: WorkspacePane = .list
    @Published var expandedOC: Set<String> = []
    @Published var showOnCall: Bool {
        didSet { UserDefaults.standard.set(showOnCall, forKey: Self.onCallKey) }
    }

    // transient
    @Published var toast: String? = nil
    @Published var confirmClear: Bool = false
    @Published var pendingDelete: [UUID]? = nil   // ids awaiting delete confirmation
    @Published var justMergedIDs: Set<UUID> = []  // merge result(s) → brief glow

    private static let onCallKey = "historyShowOnCall"
    private var lastClickIdx: Int = -1
    private var undo: [[HistoryItem]] = []
    private var toastWork: DispatchWorkItem?

    let bridge: any HistoryBridge

    init(bridge: any HistoryBridge) {
        self.bridge = bridge
        // Default ON for the new workspace; honor a previously-saved choice.
        if UserDefaults.standard.object(forKey: Self.onCallKey) == nil {
            self.showOnCall = true
        } else {
            self.showOnCall = UserDefaults.standard.bool(forKey: Self.onCallKey)
        }
    }

    // MARK: derived

    var opts: AggOptions {
        AggOptions(mode: aggMode, gapSeconds: TimeInterval(gapMin * 60), targetChars: targetChars)
    }
    var filters: HistoryFilters {
        HistoryFilters(showOnCall: showOnCall, tagFilter: tagFilter, query: query,
                       selectedDay: selectedDay, aggregate: aggregate, opts: opts)
    }

    // MARK: undo / toast

    private func pushUndo() {
        undo.append(bridge.historyItems)
        if undo.count > 12 { undo.removeFirst() }
    }
    var canUndo: Bool { !undo.isEmpty }
    func doUndo() {
        guard let snap = undo.popLast() else { return }
        bridge.replaceAll(snap)
        selection = []; toast = nil
    }
    func showToast(_ msg: String) {
        toast = msg
        toastWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.toast = nil }
        toastWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: w)
    }

    // MARK: mutations (through the bridge)

    func merge(_ ids: [UUID], asNote: Bool, title: String? = nil) {
        guard ids.count >= (asNote ? 1 : 2) else { return }
        let anchor = topMost(ids)
        pushUndo()
        withAnimation(.spring(response: 0.34, dampingFraction: 0.7)) {
            bridge.merge(ids: ids, asNote: asNote, title: title)
        }
        selection = []
        if let anchor { flashMerged([anchor]) }
        showToast(asNote ? "已整理为笔记" : "已合并 \(ids.count) 条")
    }
    /// Merge every cluster's fragments in one shot (`全部合并`).
    func mergeAll(_ clusters: [[UUID]]) {
        guard !clusters.isEmpty else { return }
        let frags = clusters.reduce(0) { $0 + $1.count }
        pushUndo()
        var anchors: Set<UUID> = []
        withAnimation(.spring(response: 0.34, dampingFraction: 0.7)) {
            for c in clusters where c.count >= 2 {
                if let a = topMost(c) { anchors.insert(a) }
                bridge.merge(ids: c, asNote: false, title: nil)
            }
        }
        selection = []
        flashMerged(anchors)
        showToast("已合并 \(clusters.count) 段 · \(frags) 句 → \(clusters.count) 条")
    }
    /// Top-most (newest) id among `ids` — the entry a merge collapses into.
    private func topMost(_ ids: [UUID]) -> UUID? {
        let idx = Dictionary(bridge.historyItems.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
        return ids.min { (idx[$0] ?? .max) < (idx[$1] ?? .max) }
    }
    /// Briefly mark the merge result(s) so their row glows, then clears.
    private func flashMerged(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        justMergedIDs.formUnion(ids)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
            self?.justMergedIDs.subtract(ids)
        }
    }
    func applyTag(_ ids: [UUID], _ tag: String) {
        let t = tag.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, !ids.isEmpty else { return }
        pushUndo()
        bridge.applyTag(ids: ids, tag: t)
        selection = []
        showToast("已为 \(ids.count) 条加上标签「\(t)」")
    }
    func delete(_ ids: [UUID]) {
        guard !ids.isEmpty else { return }
        pushUndo()
        for id in ids { bridge.delete(id: id) }
        selection = []
        showToast("已删除 \(ids.count) 条")
    }
    /// Ask for confirmation before deleting (prevents mis-taps). The view shows a
    /// dialog bound to `pendingDelete`; confirm → `confirmDelete()`. Even after
    /// deleting, the top 撤销 button restores it.
    func requestDelete(_ ids: [UUID]) { guard !ids.isEmpty else { return }; pendingDelete = ids }
    func confirmDelete() { if let ids = pendingDelete { delete(ids) }; pendingDelete = nil }
    func clearAll(count: Int) {
        pushUndo()
        bridge.clearAll()
        confirmClear = false
        showToast("已清空全部记录")
    }
    func copy(_ ids: [UUID], from entries: [HistoryItem]) {
        let set = Set(ids)
        let txt = entries.filter { set.contains($0.id) }.sorted { $0.date < $1.date }
            .map(\.text).joined(separator: "\n")
        let pb = NSPasteboard.general; pb.clearContents(); pb.setString(txt, forType: .string)
        showToast("已复制 \(ids.count) 条")
    }
    func addEntry() {
        pushUndo()
        let id = bridge.addEntry()
        editingID = id; draftText = ""; draftTitle = nil; draftTags = []
        selectedDay = nil
    }
    func mergeUp(_ id: UUID, flatIds: [UUID]) {
        guard let i = flatIds.firstIndex(of: id), i > 0 else { return }
        merge([flatIds[i - 1], id], asNote: false)
    }
    func mergeDown(_ id: UUID, flatIds: [UUID]) {
        guard let i = flatIds.firstIndex(of: id), i + 1 < flatIds.count else { return }
        merge([id, flatIds[i + 1]], asNote: false)
    }

    // MARK: editing

    func startEdit(_ e: HistoryItem) {
        editingID = e.id; draftText = e.text; draftTitle = e.title; draftTags = e.tags
    }
    func commitEdit() {
        guard let id = editingID else { return }
        let trimmed = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        pushUndo()
        if trimmed.isEmpty { bridge.delete(id: id) }
        else { bridge.update(id: id, text: draftText, title: draftTitle, tags: draftTags) }
        editingID = nil
    }
    func cancelEdit() {
        // Remove a still-blank freshly-added entry.
        if let id = editingID,
           (bridge.historyItems.first { $0.id == id }?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? "").isEmpty {
            bridge.delete(id: id)
        }
        editingID = nil
    }
    func addDraftTag(_ t: String) {
        let v = t.trimmingCharacters(in: .whitespaces)
        if !v.isEmpty, !draftTags.contains(v) { draftTags.append(v) }
    }
    func removeDraftTag(_ t: String) { draftTags.removeAll { $0 == t } }

    // MARK: selection

    func toggleSel(_ id: UUID, shift: Bool, flatIds: [UUID]) {
        guard let idx = flatIds.firstIndex(of: id) else {
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
            return
        }
        if shift, lastClickIdx >= 0, lastClickIdx < flatIds.count {
            for i in stride(from: min(lastClickIdx, idx), through: max(lastClickIdx, idx), by: 1) {
                selection.insert(flatIds[i])
            }
        } else {
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
            lastClickIdx = idx
        }
    }
    func selectAll(_ flatIds: [UUID]) { selection = Set(flatIds) }
    func selectDay(_ ids: [UUID]) { selection.formUnion(ids) }
    func clearSelection() { selection = [] }
    func toggleOC(_ nodeId: String) {
        if expandedOC.contains(nodeId) { expandedOC.remove(nodeId) } else { expandedOC.insert(nodeId) }
    }

    // MARK: keyboard (called from the view's .onKeyPress with current flatIds)

    /// Returns true if handled. `entries` is the current store list (for edit/copy).
    func handleKey(_ ch: Character, flatIds: [UUID], entries: [HistoryItem]) -> Bool {
        guard editingID == nil else { return false }
        switch ch {
        case "j": focusIdx = min(flatIds.count - 1, focusIdx + 1); return true
        case "k": focusIdx = max(0, (focusIdx < 0 ? 0 : focusIdx) - 1); return true
        case "x":
            if focusIdx >= 0, focusIdx < flatIds.count { toggleSel(flatIds[focusIdx], shift: false, flatIds: flatIds) }
            return true
        case "e":
            if focusIdx >= 0, focusIdx < flatIds.count, let en = entries.first(where: { $0.id == flatIds[focusIdx] }) { startEdit(en) }
            return true
        case "d":
            if !selection.isEmpty { requestDelete(Array(selection)) }
            else if focusIdx >= 0, focusIdx < flatIds.count { requestDelete([flatIds[focusIdx]]) }
            return true
        case "m":
            if selection.count >= 2 { merge(Array(selection), asNote: false) }
            return true
        case "a":
            selectAll(flatIds); return true
        default: return false
        }
    }

    // MARK: export (selected or all) — JSON / plain text via NSSavePanel

    func exportItems(_ items: [HistoryItem]) {
        guard !items.isEmpty else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "vibe-records.txt"
        panel.allowedContentTypes = [.plainText, .json]
        panel.isExtensionHidden = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let sorted = items.sorted { $0.date < $1.date }
        let data: Data
        if url.pathExtension.lowercased() == "json" {
            let iso = ISO8601DateFormatter()
            let arr: [[String: String]] = sorted.map {
                var d = ["date": iso.string(from: $0.date), "text": $0.text, "mode": $0.mode]
                if let t = $0.title { d["title"] = t }
                if !$0.tags.isEmpty { d["tags"] = $0.tags.joined(separator: ",") }
                return d
            }
            data = (try? JSONSerialization.data(withJSONObject: arr, options: [.prettyPrinted])) ?? Data("[]".utf8)
        } else {
            let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short
            data = Data(sorted.map { "\(f.string(from: $0.date))\n\($0.text)" }.joined(separator: "\n\n").utf8)
        }
        try? data.write(to: url, options: .atomic)
        showToast("已导出 \(items.count) 条")
    }
}
