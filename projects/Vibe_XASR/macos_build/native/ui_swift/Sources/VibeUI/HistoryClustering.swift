// ============================================================
//  Vibe XASR — History clustering / grouping (pure logic)
//
//  Ports the design prototype's rule-based aggregation (app.jsx / calendar.jsx)
//  to Swift value types: day grouping, fragment clustering (by pause-gap or
//  cumulative chars), OnCall run folding, and calendar helpers. No SwiftUI here
//  — kept Foundation-only and deterministic so it's trivially testable.
// ============================================================

import Foundation

// MARK: - Small helpers

/// Visible character count (whitespace stripped) — matches the prototype's
/// `charCount = s.replace(/\s/g,"").length`. CJK each count 1.
public func historyCharCount(_ s: String) -> Int {
    s.reduce(0) { $1.isWhitespace ? $0 : $0 + 1 }
}

/// Local "Y-M-D" key (month/day NOT zero-padded), matching the prototype's dayKey.
public func historyDayKey(_ date: Date, _ cal: Calendar = .current) -> String {
    let c = cal.dateComponents([.year, .month, .day], from: date)
    return "\(c.year ?? 0)-\(c.month ?? 0)-\(c.day ?? 0)"
}

// MARK: - Aggregation options

public enum AggMode: String { case pause, chars }

public struct AggOptions {
    public var mode: AggMode
    public var gapSeconds: TimeInterval     // pause threshold (gapMin * 60)
    public var targetChars: Int             // chars-mode paragraph target
    /// Chars-mode never bridges a gap longer than this (avoid merging across
    /// unrelated sessions) — the prototype's 15-minute hard break.
    public static let hardBreakSeconds: TimeInterval = 15 * 60

    public init(mode: AggMode = .pause, gapSeconds: TimeInterval = 120, targetChars: Int = 120) {
        self.mode = mode; self.gapSeconds = gapSeconds; self.targetChars = targetChars
    }
}

// MARK: - Display nodes

/// A node in a day's list: a lone fragment, a cluster of consecutive fragments,
/// or a folded run of consecutive OnCall blocks. `entries` are ASCENDING by date.
public enum HNode: Identifiable {
    case single(HistoryItem)
    case cluster([HistoryItem])
    case oncall([HistoryItem])

    public var id: String {
        switch self {
        case .single(let e):   return "s-\(e.id.uuidString)"
        case .cluster(let a):  return "cl-\(a.first?.id.uuidString ?? "")"
        case .oncall(let a):   return "oc-\(a.first?.id.uuidString ?? "")"
        }
    }
}

public struct DayGroup: Identifiable {
    public let key: String
    public let date: Date           // representative ts (newest in the day)
    public let nodes: [HNode]       // newest-first for display
    public let count: Int
    public var id: String { key }
}

// MARK: - Filters

public struct HistoryFilters {
    public var showOnCall: Bool
    public var tagFilter: String?
    public var query: String
    public var selectedDay: String?
    public var aggregate: Bool
    public var opts: AggOptions
    public init(showOnCall: Bool = true, tagFilter: String? = nil, query: String = "",
                selectedDay: String? = nil, aggregate: Bool = true, opts: AggOptions = .init()) {
        self.showOnCall = showOnCall; self.tagFilter = tagFilter; self.query = query
        self.selectedDay = selectedDay; self.aggregate = aggregate; self.opts = opts
    }
}

// MARK: - Clustering

/// Subdivide a run of consecutive non-OnCall fragments (ASC by date) by the rule.
func historySubdivide(_ run: [HistoryItem], _ opts: AggOptions) -> [[HistoryItem]] {
    guard run.count >= 2 else { return [run] }
    var subs: [[HistoryItem]] = []
    if opts.mode == .chars {
        var cur: [HistoryItem] = []
        var sum = 0
        for k in run.indices {
            let big = k > 0 && run[k].date.timeIntervalSince(run[k - 1].date) > AggOptions.hardBreakSeconds
            if big, !cur.isEmpty { subs.append(cur); cur = []; sum = 0 }
            cur.append(run[k]); sum += historyCharCount(run[k].text)
            if sum >= opts.targetChars { subs.append(cur); cur = []; sum = 0 }
        }
        if !cur.isEmpty { subs.append(cur) }
    } else {
        var cur: [HistoryItem] = [run[0]]
        for k in 1..<run.count {
            if run[k].date.timeIntervalSince(run[k - 1].date) <= opts.gapSeconds { cur.append(run[k]) }
            else { subs.append(cur); cur = [run[k]] }
        }
        subs.append(cur)
    }
    return subs
}

/// Turn a day's ASC entries into display nodes (OnCall runs folded; non-OnCall
/// runs subdivided into clusters when aggregating).
func historyClusterize(_ asc: [HistoryItem], aggregate: Bool, _ opts: AggOptions) -> [HNode] {
    var nodes: [HNode] = []
    var i = 0
    while i < asc.count {
        if asc[i].mode == "oncall" {
            var j = i; var arr: [HistoryItem] = []
            while j < asc.count, asc[j].mode == "oncall" { arr.append(asc[j]); j += 1 }
            nodes.append(.oncall(arr)); i = j; continue
        }
        var j = i; var run: [HistoryItem] = []
        while j < asc.count, asc[j].mode != "oncall" { run.append(asc[j]); j += 1 }
        i = j
        if !aggregate { run.forEach { nodes.append(.single($0)) }; continue }
        for arr in historySubdivide(run, opts) {
            if arr.count >= 2 { nodes.append(.cluster(arr)) }
            else { arr.forEach { nodes.append(.single($0)) } }
        }
    }
    return nodes
}

/// Filter → group by day (newest day first) → clusterize each day → newest-first nodes.
public func historyBuildGroups(_ entries: [HistoryItem], _ f: HistoryFilters,
                               _ cal: Calendar = .current) -> [DayGroup] {
    let q = f.query.trimmingCharacters(in: .whitespaces)
    let items = entries.filter { e in
        if !f.showOnCall, e.mode == "oncall" { return false }
        if let tf = f.tagFilter, !e.tags.contains(tf) { return false }
        if !q.isEmpty {
            let inText = e.text.localizedCaseInsensitiveContains(q)
            let inTitle = e.title?.localizedCaseInsensitiveContains(q) ?? false
            let inTags = e.tags.contains { $0.localizedCaseInsensitiveContains(q) }
            if !(inText || inTitle || inTags) { return false }
        }
        if let sd = f.selectedDay, historyDayKey(e.date, cal) != sd { return false }
        return true
    }
    // entries are newest-first → byDay[k][0] is the newest in that day.
    var byDay: [String: [HistoryItem]] = [:]
    var order: [String] = []
    for e in items {
        let k = historyDayKey(e.date, cal)
        if byDay[k] == nil { byDay[k] = []; order.append(k) }
        byDay[k]?.append(e)
    }
    let keys = order.sorted { (byDay[$0]?.first?.date ?? .distantPast) > (byDay[$1]?.first?.date ?? .distantPast) }
    return keys.map { k in
        let day = byDay[k] ?? []
        let asc = day.sorted { $0.date < $1.date }
        let nodes = Array(historyClusterize(asc, aggregate: f.aggregate, f.opts).reversed())
        return DayGroup(key: k, date: day.first?.date ?? Date(), nodes: nodes, count: day.count)
    }
}

// MARK: - Calendar helpers

/// 6×7 (=42) Monday-first grid of Dates covering the month containing `cursor`.
public func historyMonthGrid(_ cursor: Date, _ cal: Calendar = .current) -> [Date] {
    let comps = cal.dateComponents([.year, .month], from: cursor)
    guard let first = cal.date(from: comps) else { return [] }
    let weekday = cal.component(.weekday, from: first)   // 1=Sun … 7=Sat
    let lead = (weekday + 5) % 7                          // Monday-first lead
    guard let start = cal.date(byAdding: .day, value: -lead, to: first) else { return [] }
    return (0..<42).compactMap { cal.date(byAdding: .day, value: $0, to: start) }
}

/// Heatmap intensity 0–4 from a day's count vs the month max.
public func historyHeatLevel(_ n: Int, max: Int) -> Int {
    guard n > 0 else { return 0 }
    let r = Double(n) / Double(Swift.max(1, max))
    if r > 0.66 { return 4 }
    if r > 0.40 { return 3 }
    if r > 0.15 { return 2 }
    return 1
}
