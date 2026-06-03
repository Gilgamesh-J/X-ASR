// ============================================================
//  Vibe XASR — History workspace (main view)
//
//  The redesigned 记录 surface: day-grouped fragment list with rule-based
//  clustering + one-click merge, multi-select + bulk ops, topic tags, a mini
//  calendar rail + month heatmap, search, keyboard flow and undo. Used both
//  embedded in the Settings 记录 tab and in the standalone History window.
//  Derivations (groups / flatIds / tags / counts / stats) are computed here from
//  the host store; mutation/selection state lives in HistoryWorkspaceModel.
// ============================================================

import SwiftUI
import AppKit

public struct HistoryWorkspace<Store: HistoryBridge & ObservableObject>: View {
    @ObservedObject private var store: Store
    @ObservedObject private var l10n: L10n
    @StateObject private var model: HistoryWorkspaceModel
    @Environment(\.colorScheme) private var scheme
    @FocusState private var listFocused: Bool

    public init(store: Store, l10n: L10n = .shared) {
        _store = ObservedObject(wrappedValue: store)
        _l10n = ObservedObject(wrappedValue: l10n)
        _model = StateObject(wrappedValue: HistoryWorkspaceModel(bridge: store))
    }

    public var body: some View {
        let entries = store.historyItems
        let today = historyDayKey(Date())
        let yest = historyDayKey(Calendar.current.date(byAdding: .day, value: -1, to: Date()) ?? Date())
        let groups = historyBuildGroups(entries, model.filters)
        let flatIds = Self.computeFlatIds(groups, expandedOC: model.expandedOC)
        let flatIndexOf = Dictionary(flatIds.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        let counts = Self.dayCounts(entries)
        let tags = Self.allTags(entries)
        let clusterLists = Self.clusterLists(groups)

        GeometryReader { geo in
            let showRail = geo.size.width >= 900
            VStack(spacing: 0) {
                header(entries: entries)
                toolbar
                if !tags.isEmpty { tagBar(tags) }
                if let sd = model.selectedDay { dayFilterBar(sd, entries: entries, today: today, yest: yest) }
                Divider().overlay(Vibe.Palette.hairline(scheme))
                HStack(spacing: 0) {
                    mainArea(entries: entries, groups: groups, flatIds: flatIds,
                             flatIndexOf: flatIndexOf, tagNames: tags.map(\.name),
                             counts: counts, clusterLists: clusterLists, today: today, yest: yest)
                    if showRail, model.pane == .list {
                        rail(counts: counts, today: today)
                    }
                }
                shortcutsBar
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Vibe.Palette.surface(scheme))
            .overlay(alignment: .bottom) {
                if !model.selection.isEmpty {
                    BulkBar(model: model, entries: entries, allTagNames: tags.map(\.name))
                        .padding(.bottom, 46)
                }
            }
            .overlay(alignment: .bottom) { ToastBar(model: model).padding(.bottom, 104) }
            .animation(.easeOut(duration: 0.15), value: model.selection.isEmpty)
            .animation(.easeOut(duration: 0.15), value: model.toast)
        }
        .frame(minWidth: 720, minHeight: 420)
        .confirmationDialog("确定清空全部记录?", isPresented: $model.confirmClear, titleVisibility: .visible) {
            Button("清空(不可恢复)", role: .destructive) { model.clearAll(count: entries.count) }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将永久删除全部 \(entries.count) 条本地记录,可撤销一次。")
        }
        .confirmationDialog("删除选中的记录?", isPresented: Binding(
            get: { model.pendingDelete != nil },
            set: { if !$0 { model.pendingDelete = nil } }), titleVisibility: .visible) {
            Button("删除 \(model.pendingDelete?.count ?? 0) 条", role: .destructive) { model.confirmDelete() }
            Button("取消", role: .cancel) { model.pendingDelete = nil }
        } message: {
            Text("删除后可用顶部「撤销」恢复。")
        }
        .sheet(isPresented: Binding(
            get: { model.editingID != nil },
            set: { if !$0 { model.cancelEdit() } })) {
            HistoryEditSheet(model: model, allTagNames: tags.map(\.name))
        }
    }

    // MARK: header

    private func header(entries: [HistoryItem]) -> some View {
        let chars = entries.reduce(0) { $0 + historyCharCount($1.text) }
        let mins = max(0, chars / 200)
        return HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Vibe.accentGradient)
                .frame(width: 30, height: 30)
                .overlay(LogoBars(heights: [6, 12, 8], barW: 2.5, gap: 2.5))
            Text("历史").font(Vibe.Fonts.ui(20, weight: .bold)).foregroundStyle(Vibe.Palette.text(scheme))
            Text("\(entries.count) 条").font(Vibe.Fonts.ui(13, weight: .medium)).foregroundStyle(Vibe.Palette.textMuted(scheme))
            (Text(" · 累计 ") + Text(verbatim: String(chars)).font(Vibe.Fonts.mono(13)).bold() + Text(" 字 · 省 ") + Text(verbatim: String(mins)).font(Vibe.Fonts.mono(13)).bold() + Text(" 分"))
                .font(Vibe.Fonts.ui(13)).foregroundStyle(Vibe.Palette.textMuted(scheme))
            onCallCheck
            Spacer()
            undoButton
            privacyPill
            HBtn(title: "导出", system: "square.and.arrow.up") { model.exportItems(entries) }
            HBtn(title: "全部清空", kind: .danger) { model.confirmClear = true }
        }
        .padding(.horizontal, 20).padding(.vertical, 13)
        .background(Vibe.Palette.surface2(scheme))
    }

    private var onCallCheck: some View {
        Button { model.showOnCall.toggle() } label: {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 5).fill(model.showOnCall ? Vibe.Palette.accentA : .clear)
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(model.showOnCall ? Vibe.Palette.accentA : Vibe.Palette.hairlineStrong(scheme), lineWidth: 1.5))
                    .overlay(model.showOnCall ? Image(systemName: "checkmark").font(.system(size: 8, weight: .bold)).foregroundStyle(.white) : nil)
                    .frame(width: 16, height: 16)
                Text("显示 OnCall 内容").font(Vibe.Fonts.ui(12))
                    .foregroundStyle(model.showOnCall ? Vibe.Palette.text(scheme) : Vibe.Palette.textMuted(scheme))
            }
        }.buttonStyle(.plain).padding(.leading, 4)
    }

    private var privacyPill: some View {
        HStack(spacing: 6) {
            Image(systemName: "lock.fill").font(.system(size: 11))
            Text("本地").font(Vibe.Fonts.ui(12.5, weight: .semibold))
        }
        .foregroundStyle(Vibe.Palette.success)
        .padding(.horizontal, 11).frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 8).fill(Vibe.Palette.success.opacity(0.12)))
        .help("您的数据永远保存在本地,绝不上云 · Your data stays on this device — never uploaded.")
    }

    /// Fixed, prominent undo (top header). Always present; dim + disabled when the
    /// undo stack is empty. Mutations are persisted immediately, so this restores
    /// the last on-disk change rather than buffering it.
    private var undoButton: some View {
        Button { model.doUndo() } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.uturn.backward").font(.system(size: 13, weight: .semibold))
                Text("撤销").font(Vibe.Fonts.ui(13, weight: .semibold))
            }
            .foregroundStyle(model.canUndo ? Vibe.Palette.accentA : Vibe.Palette.textFaint(scheme))
            .padding(.horizontal, 14).frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(model.canUndo ? Vibe.Palette.accentSoft(scheme) : Vibe.Palette.surface2(scheme)))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(model.canUndo ? Vibe.Palette.accentA.opacity(0.45) : .clear, lineWidth: 1))
        }
        .buttonStyle(.plain).disabled(!model.canUndo)
        .help("撤销上一步操作")
    }

    // MARK: toolbar

    private var toolbar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.system(size: 13)).foregroundStyle(Vibe.Palette.textFaint(scheme))
                TextField("搜索记录…", text: $model.query).textFieldStyle(.plain).font(Vibe.Fonts.ui(13))
            }
            .padding(.horizontal, 11).frame(height: 32).frame(maxWidth: 340)
            .background(RoundedRectangle(cornerRadius: 8).fill(Vibe.Palette.surface2(scheme)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Vibe.Palette.hairline(scheme), lineWidth: 1))

            HBtn(title: "新建", system: "plus") { model.addEntry() }
            Spacer()
            chip(label: "自动聚合", system: "arrow.triangle.merge", on: model.aggregate) { model.aggregate.toggle() }
            if model.aggregate {
                Button { model.aggOpen.toggle() } label: {
                    HStack(spacing: 6) {
                        Text(model.aggMode == .pause ? "停顿 ≤\(model.gapMin)分" : "每 \(model.targetChars) 字").font(Vibe.Fonts.ui(12, weight: .semibold))
                        Image(systemName: "slider.horizontal.3").font(.system(size: 11))
                    }
                    .foregroundStyle(Vibe.Palette.textMuted(scheme))
                    .padding(.horizontal, 12).frame(height: 30)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Vibe.Palette.surface2(scheme)))
                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Vibe.Palette.hairline(scheme), lineWidth: 1))
                }.buttonStyle(.plain)
                .popover(isPresented: $model.aggOpen, arrowEdge: .bottom) { AggPopover(model: model) }
            }
            Picker("", selection: $model.pane) {
                Text("列表").tag(WorkspacePane.list)
                Text("日历").tag(WorkspacePane.calendar)
            }.pickerStyle(.segmented).labelsHidden().frame(width: 130)
        }
        .padding(.horizontal, 20).padding(.vertical, 11)
        .background(Vibe.Palette.surface(scheme))
        .overlay(alignment: .bottom) { Divider().overlay(Vibe.Palette.hairline(scheme)) }
    }

    private func chip(label: String, system: String, on: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) { Image(systemName: system).font(.system(size: 12)); Text(label).font(Vibe.Fonts.ui(12.5, weight: .semibold)) }
                .foregroundStyle(on ? Vibe.Palette.text(scheme) : Vibe.Palette.textMuted(scheme))
                .padding(.horizontal, 12).frame(height: 30)
                .background(RoundedRectangle(cornerRadius: 7).fill(on ? Vibe.Palette.accentSoft(scheme) : Vibe.Palette.surface2(scheme)))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(on ? Vibe.Palette.accentA.opacity(0.5) : Vibe.Palette.hairline(scheme), lineWidth: 1))
        }.buttonStyle(.plain)
    }

    // MARK: tag bar

    private func tagBar(_ tags: [(name: String, count: Int)]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Image(systemName: "tag").font(.system(size: 12)).foregroundStyle(Vibe.Palette.textFaint(scheme))
                Button { model.tagFilter = nil } label: {
                    Text("全部").font(Vibe.Fonts.ui(12, weight: .semibold))
                        .foregroundStyle(model.tagFilter == nil ? Vibe.Palette.surface(scheme) : Vibe.Palette.textMuted(scheme))
                        .padding(.horizontal, 11).frame(height: 24)
                        .background(Capsule().fill(model.tagFilter == nil ? Vibe.Palette.text(scheme) : Vibe.Palette.surface2(scheme)))
                }.buttonStyle(.plain)
                ForEach(tags, id: \.name) { t in
                    TagChip(name: t.name, count: t.count, active: model.tagFilter == t.name,
                            onTap: { model.tagFilter = (model.tagFilter == t.name ? nil : t.name) })
                }
            }
            .padding(.horizontal, 20).padding(.vertical, 9)
        }
        .background(Vibe.Palette.surface(scheme))
        .overlay(alignment: .bottom) { Divider().overlay(Vibe.Palette.hairline(scheme)) }
    }

    private func dayFilterBar(_ sd: String, entries: [HistoryItem], today: String, yest: String) -> some View {
        let d = entries.first { historyDayKey($0.date) == sd }?.date ?? Date()
        return HStack(spacing: 10) {
            Image(systemName: "calendar").font(.system(size: 13)).foregroundStyle(Vibe.Palette.accentA)
            Text("正在查看 ").font(Vibe.Fonts.ui(13)).foregroundStyle(Vibe.Palette.text(scheme))
            + Text(histDayLabel(sd, d, todayKey: today, yestKey: yest)).font(Vibe.Fonts.ui(13, weight: .bold)).foregroundStyle(Vibe.Palette.text(scheme))
            Spacer()
            HBtn(title: "查看全部") { model.selectedDay = nil }
        }
        .padding(.horizontal, 20).padding(.vertical, 10)
        .background(Vibe.Palette.accentSoft(scheme))
    }

    // MARK: main area

    @ViewBuilder
    private func mainArea(entries: [HistoryItem], groups: [DayGroup], flatIds: [UUID],
                          flatIndexOf: [UUID: Int], tagNames: [String], counts: [String: Int],
                          clusterLists: [[UUID]], today: String, yest: String) -> some View {
        if model.pane == .calendar {
            ScrollView {
                MonthHeatmap(counts: counts, selected: model.selectedDay, todayKey: today) { k in
                    model.selectedDay = k; model.pane = .list
                }.padding(20)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Vibe.Palette.surface(scheme))
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 1, pinnedViews: [.sectionHeaders]) {
                        if model.aggregate, clusterLists.count > 0 {
                            aggBar(clusterLists: clusterLists)
                        }
                        if groups.isEmpty {
                            VStack(spacing: 10) {
                                Image(systemName: "magnifyingglass").font(.system(size: 26)).foregroundStyle(Vibe.Palette.textFaint(scheme))
                                Text(model.query.isEmpty && model.tagFilter == nil ? "暂无记录" : "没有匹配的记录")
                                    .font(Vibe.Fonts.ui(13)).foregroundStyle(Vibe.Palette.textMuted(scheme))
                            }.frame(maxWidth: .infinity).padding(.top, 80)
                        }
                        ForEach(groups) { g in
                            Section {
                                ForEach(g.nodes) { node in
                                    nodeView(node, flatIds: flatIds, flatIndexOf: flatIndexOf, tagNames: tagNames).id(node.id)
                                }
                            } header: {
                                dayHeader(g, entries: entries, today: today, yest: yest)
                            }
                        }
                        Color.clear.frame(height: 80)
                    }
                    .padding(.horizontal, 10)
                }
                .background(Vibe.Palette.surface(scheme))
                .focusable()
                .focusEffectDisabled()
                .focused($listFocused)
                .onKeyPress { press in
                    // Never steal keys while typing in a text field / editor / IME
                    // composition (search, tag input, inline editor, tag menu…).
                    if isTextInputActive() || model.editingID != nil { return .ignored }
                    if let ch = press.characters.lowercased().first,
                       model.handleKey(ch, flatIds: flatIds, entries: entries) {
                        if let id = (model.focusIdx >= 0 && model.focusIdx < flatIds.count) ? flatIds[model.focusIdx] : nil {
                            withAnimation { proxy.scrollTo(id, anchor: .center) }
                        }
                        return .handled
                    }
                    if press.key == .escape { model.clearSelection(); model.focusIdx = -1; return .handled }
                    return .ignored
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func aggBar(clusterLists: [[UUID]]) -> some View {
        let frags = clusterLists.reduce(0) { $0 + $1.count }
        return HStack(spacing: 10) {
            Image(systemName: "arrow.triangle.merge").font(.system(size: 14)).foregroundStyle(Vibe.Palette.accentA)
            (Text(model.aggMode == .pause ? "按 ≤\(model.gapMin) 分钟 停顿聚合" : "按 每 \(model.targetChars) 字 聚合")
             + Text(" · 发现 ") + Text("\(clusterLists.count)").bold() + Text(" 段连续碎句（共 \(frags) 句）"))
                .font(Vibe.Fonts.ui(13)).foregroundStyle(Vibe.Palette.text(scheme))
            Spacer()
            HBtn(title: "全部合并 → \(clusterLists.count) 条", system: "arrow.triangle.merge", kind: .accent) {
                model.mergeAll(clusterLists)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Vibe.Palette.accentSoft(scheme)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Vibe.Palette.accentA.opacity(0.5), lineWidth: 1))
        .padding(.vertical, 8)
    }

    private func dayHeader(_ g: DayGroup, entries: [HistoryItem], today: String, yest: String) -> some View {
        HStack(spacing: 10) {
            Text(histDayLabel(g.key, g.date, todayKey: today, yestKey: yest))
                .font(Vibe.Fonts.ui(12.5, weight: .bold)).foregroundStyle(Vibe.Palette.textMuted(scheme))
            Text("\(g.count) 条").font(Vibe.Fonts.ui(11)).foregroundStyle(Vibe.Palette.textFaint(scheme))
                .padding(.horizontal, 8).padding(.vertical, 2).background(Capsule().fill(Vibe.Palette.surface2(scheme)))
            Rectangle().fill(Vibe.Palette.hairline(scheme)).frame(height: 1)
            HIconButton(symbol: "checkmark.circle", size: 26, help: "全选当天") {
                let ids = entries.filter { historyDayKey($0.date) == g.key }.map(\.id)
                model.selectDay(ids)
            }
        }
        .padding(.vertical, 8).padding(.horizontal, 10)
        .background(Vibe.Palette.surface(scheme))
    }

    @ViewBuilder
    private func nodeView(_ node: HNode, flatIds: [UUID], flatIndexOf: [UUID: Int], tagNames: [String]) -> some View {
        switch node {
        case .single(let e):
            FragRow(model: model, entry: e, flatIndex: flatIndexOf[e.id] ?? -1, flatIds: flatIds,
                    canMergeUp: (flatIndexOf[e.id] ?? 0) > 0,
                    canMergeDown: (flatIndexOf[e.id] ?? 0) < flatIds.count - 1,
                    allTagNames: tagNames)
        case .cluster(let a):
            ClusterWrap(model: model, entries: a) {
                ForEach(a.reversed()) { e in
                    FragRow(model: model, entry: e, flatIndex: flatIndexOf[e.id] ?? -1, flatIds: flatIds,
                            canMergeUp: false, canMergeDown: false, allTagNames: tagNames)
                }
            }
        case .oncall(let a):
            OnCallBlock(model: model, nodeId: node.id, entries: a) {
                ForEach(a.reversed()) { e in
                    FragRow(model: model, entry: e, flatIndex: flatIndexOf[e.id] ?? -1, flatIds: flatIds,
                            canMergeUp: false, canMergeDown: false, allTagNames: tagNames)
                }
            }
        }
    }

    // MARK: rail

    private func rail(counts: [String: Int], today: String) -> some View {
        let monthPrefix = { () -> String in
            let c = Calendar.current.dateComponents([.year, .month], from: Date())
            return "\(c.year ?? 0)-\(c.month ?? 0)"
        }()
        let monthCount = counts.filter { $0.key.hasPrefix(monthPrefix + "-") || $0.key == monthPrefix }.values.reduce(0, +)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "calendar").font(.system(size: 13)).foregroundStyle(Vibe.Palette.textMuted(scheme))
                Text("日历").font(Vibe.Fonts.ui(12, weight: .bold)).foregroundStyle(Vibe.Palette.textMuted(scheme)).tracking(0.5)
            }.padding(.bottom, 12)
            MiniCalendar(counts: counts, selected: model.selectedDay, todayKey: today) { model.selectedDay = $0 }
            VStack(spacing: 9) {
                railStat("本月记录", "\(monthCount) 条")
                railStat("活跃天数", "\(counts.keys.count) 天")
            }
            .padding(.top, 14).overlay(alignment: .top) { Rectangle().fill(Vibe.Palette.hairline(scheme)).frame(height: 1) }
            .padding(.top, 4)
            Spacer()
        }
        .padding(16).frame(width: 262)
        .background(Vibe.Palette.surface2(scheme))
        .overlay(alignment: .leading) { Rectangle().fill(Vibe.Palette.hairline(scheme)).frame(width: 1) }
    }

    private func railStat(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(Vibe.Fonts.ui(12.5)).foregroundStyle(Vibe.Palette.textMuted(scheme))
            Spacer()
            Text(value).font(Vibe.Fonts.mono(12.5, weight: .bold)).foregroundStyle(Vibe.Palette.text(scheme))
        }
    }

    // MARK: shortcuts

    private var shortcutsBar: some View {
        HStack(spacing: 14) {
            kb(["J", "K"], "移动"); kb(["X"], "选择"); kb(["E"], "编辑")
            kb(["D"], "删除"); kb(["M"], "合并所选"); kb(["A"], "全选"); kb(["Esc"], "取消")
            Spacer()
            Text("Shift+点击 选范围").font(Vibe.Fonts.ui(11)).foregroundStyle(Vibe.Palette.textFaint(scheme))
        }
        .padding(.horizontal, 20).padding(.vertical, 7)
        .background(Vibe.Palette.surface2(scheme))
        .overlay(alignment: .top) { Divider().overlay(Vibe.Palette.hairline(scheme)) }
    }
    private func kb(_ keys: [String], _ label: String) -> some View {
        HStack(spacing: 5) {
            ForEach(keys, id: \.self) { KbdKey(label: $0) }
            Text(label).font(Vibe.Fonts.ui(11)).foregroundStyle(Vibe.Palette.textFaint(scheme))
        }
    }

    /// True while any text field / editor / IME field is the first responder — used
    /// to suppress single-key shortcuts so they don't fight typing or composition.
    private func isTextInputActive() -> Bool {
        guard let r = NSApp.keyWindow?.firstResponder else { return false }
        return r is NSTextView || r is NSTextField
    }

    // MARK: derivations (static, pure)

    private static func computeFlatIds(_ groups: [DayGroup], expandedOC: Set<String>) -> [UUID] {
        var ids: [UUID] = []
        for g in groups {
            for n in g.nodes {
                switch n {
                case .single(let e): ids.append(e.id)
                case .cluster(let a): a.reversed().forEach { ids.append($0.id) }
                case .oncall(let a): if expandedOC.contains(n.id) { a.reversed().forEach { ids.append($0.id) } }
                }
            }
        }
        return ids
    }
    private static func dayCounts(_ entries: [HistoryItem]) -> [String: Int] {
        var c: [String: Int] = [:]
        for e in entries { c[historyDayKey(e.date), default: 0] += 1 }
        return c
    }
    private static func allTags(_ entries: [HistoryItem]) -> [(name: String, count: Int)] {
        var m: [String: Int] = [:]
        for e in entries { for t in e.tags { m[t, default: 0] += 1 } }
        return m.sorted { $0.value > $1.value }.map { (name: $0.key, count: $0.value) }
    }
    private static func clusterLists(_ groups: [DayGroup]) -> [[UUID]] {
        var out: [[UUID]] = []
        for g in groups { for n in g.nodes { if case .cluster(let a) = n { out.append(a.map(\.id)) } } }
        return out
    }
}
