// ============================================================
//  Vibe XASR — History workspace row + control components
//  Rows, clusters, OnCall folds, tag chips, aggregation popover, tag menu,
//  bulk bar, toast. Each observes the shared HistoryWorkspaceModel.
// ============================================================

import SwiftUI
import AppKit

// MARK: - Time / day formatting

@MainActor func histTimeString(_ d: Date) -> String {
    let c = Calendar.current.dateComponents([.hour, .minute], from: d)
    var h = c.hour ?? 0
    let ap = (h < 12) ? L10n.shared.t("hist.am") : L10n.shared.t("hist.pm")
    if h == 0 { h = 12 } else if h > 12 { h -= 12 }
    return "\(ap)\(h):" + String(format: "%02d", c.minute ?? 0)
}
@MainActor func histFullTimeString(_ d: Date) -> String {
    let c = Calendar.current.dateComponents([.year, .month, .day], from: d)
    return L10n.shared.t("hist.date.full", c.year ?? 0, c.month ?? 0, c.day ?? 0) + histTimeString(d)
}
@MainActor func histDayLabel(_ key: String, _ d: Date, todayKey: String, yestKey: String) -> String {
    if key == todayKey { return L10n.shared.t("hist.today") }
    if key == yestKey { return L10n.shared.t("hist.yesterday") }
    let c = Calendar.current.dateComponents([.month, .day, .weekday], from: d)
    let wd = L10n.shared.weekdayShort((c.weekday ?? 1) - 1)
    return L10n.shared.t("hist.date.md", c.month ?? 0, c.day ?? 0, wd)
}

// MARK: - Tag color

private let kTagPalette = ["#7C5CFF", "#5B8CFF", "#46C98B", "#E0894A", "#E05A8A", "#42B8C8", "#B07CF2", "#D0A92E"]
func historyTagColor(_ name: String) -> Color {
    var h: UInt32 = 0
    for s in name.unicodeScalars { h = (h &* 31 &+ s.value) }
    return Color(hex: kTagPalette[Int(h % UInt32(kTagPalette.count))])
}

// MARK: - Small shared controls

struct HIconButton: View {
    var symbol: String
    var danger: Bool = false
    var size: CGFloat = 30
    var help: String? = nil
    var action: () -> Void
    @Environment(\.colorScheme) private var scheme
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13))
                .foregroundStyle(hovering ? (danger ? Vibe.Palette.error : Vibe.Palette.accentA)
                                          : Vibe.Palette.textFaint(scheme))
                .frame(width: size, height: size - 4)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(hovering ? Vibe.Palette.surface2(scheme) : .clear))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help ?? "")
    }
}

struct HBtn: View {
    enum Kind { case plain, accent, danger }
    var title: String? = nil
    var system: String? = nil
    var kind: Kind = .plain
    var disabled = false
    var action: () -> Void
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let system { Image(systemName: system).font(.system(size: 12, weight: .semibold)) }
                if let title { Text(title).font(Vibe.Fonts.ui(12, weight: .semibold)) }
            }
            .foregroundStyle(fg).padding(.horizontal, 10).frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(bg))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(kind == .plain ? Vibe.Palette.hairlineStrong(scheme) : .clear, lineWidth: 1))
        }
        .buttonStyle(.plain).disabled(disabled).opacity(disabled ? 0.4 : 1)
    }
    private var fg: Color {
        switch kind {
        case .accent: return .white
        case .danger: return Vibe.Palette.error
        case .plain:  return Vibe.Palette.text(scheme)
        }
    }
    private var bg: Color {
        switch kind {
        case .accent: return Vibe.Palette.accentA
        case .danger: return .clear
        case .plain:  return Vibe.Palette.surface2(scheme)
        }
    }
}

struct KbdKey: View {
    let label: String
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        Text(label).font(Vibe.Fonts.mono(10.5))
            .foregroundStyle(Vibe.Palette.textMuted(scheme))
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 5).fill(Vibe.Palette.surface2(scheme)))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Vibe.Palette.hairlineStrong(scheme), lineWidth: 1))
    }
}

// MARK: - Tag chip

struct TagChip: View {
    let name: String
    var count: Int? = nil
    var active: Bool = false
    var onTap: (() -> Void)? = nil
    var onRemove: (() -> Void)? = nil
    var body: some View {
        let c = historyTagColor(name)
        HStack(spacing: 5) {
            Circle().fill(c).frame(width: 6, height: 6)
            Text(name).font(Vibe.Fonts.ui(11.5, weight: .semibold))
            if let count { Text("\(count)").font(Vibe.Fonts.mono(10.5)).opacity(0.65) }
            if let onRemove {
                Button(action: onRemove) { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)) }
                    .buttonStyle(.plain).opacity(0.6)
            }
        }
        .foregroundStyle(c)
        .padding(.horizontal, 8).frame(height: onTap != nil ? 24 : 22)
        .background(Capsule().fill(c.opacity(0.12)))
        .overlay(Capsule().strokeBorder(c.opacity(active ? 1 : 0.33), lineWidth: active ? 1.5 : 1))
        .contentShape(Capsule())
        .onTapGesture { onTap?() }
    }
}

// MARK: - Fragment row

struct FragRow: View {
    @ObservedObject var model: HistoryWorkspaceModel
    @ObservedObject var l10n: L10n = .shared
    let entry: HistoryItem
    let flatIndex: Int
    let flatIds: [UUID]
    let canMergeUp: Bool
    let canMergeDown: Bool
    let allTagNames: [String]
    @Environment(\.colorScheme) private var scheme
    @State private var hovering = false
    @State private var tagPop = false
    @State private var flash: Double = 0          // merge-result glow (1 → 0)

    private var selected: Bool { model.selection.contains(entry.id) }
    private var focused: Bool { flatIndex >= 0 && model.focusIdx == flatIndex }

    // Editing is now a pop-out sheet (HistoryEditSheet), so the row stays read-only.
    var body: some View { row }

    // ----- read mode -----
    private var row: some View {
        HStack(alignment: .top, spacing: 12) {
            // The whole checkbox + text area is ONE big selection target: click
            // toggles, ⇧-click extends the range. Far easier than a tiny checkbox.
            Button {
                model.toggleSel(entry.id, shift: NSEvent.modifierFlags.contains(.shift), flatIds: flatIds)
            } label: {
                HStack(alignment: .top, spacing: 12) {
                    checkboxIndicator
                    VStack(alignment: .leading, spacing: 5) {
                        if let title = entry.title {
                            Text(title).font(Vibe.Fonts.ui(14, weight: .bold))
                                .foregroundStyle(Vibe.Palette.accentA)
                        }
                        Text(entry.text)
                            .font(Vibe.Fonts.mono(14)).foregroundStyle(Vibe.Palette.text(scheme))
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .multilineTextAlignment(.leading)
                        HStack(spacing: 9) {
                            Text(histFullTimeString(entry.date))
                                .font(Vibe.Fonts.mono(11)).foregroundStyle(Vibe.Palette.textFaint(scheme))
                            if historyCharCount(entry.text) <= 6 {
                                Text(l10n.t("hist.frag")).font(Vibe.Fonts.ui(10))
                                    .foregroundStyle(Vibe.Palette.textFaint(scheme))
                                    .padding(.horizontal, 6).padding(.vertical, 1)
                                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Vibe.Palette.hairline(scheme), lineWidth: 1))
                            }
                            ForEach(entry.tags, id: \.self) { TagChip(name: $0) }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 8).padding(.horizontal, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowBackground)
        .overlay(alignment: .leading) {
            if entry.title != nil {
                Rectangle().fill(Vibe.Palette.accentA.opacity(0.5)).frame(width: 2).allowsHitTesting(false)
            }
        }
        .overlay(alignment: .topTrailing) { actionsOverlay }
        .overlay(RoundedRectangle(cornerRadius: 9)
            .strokeBorder(focused ? Vibe.Palette.accentA.opacity(0.5) : .clear, lineWidth: 1.5)
            .allowsHitTesting(false))
        .overlay(  // bright "merge done" glow — accent-gradient pulse that fades out
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Vibe.accentGradient).opacity(0.18 * flash)
                RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Vibe.accentGradient, lineWidth: 2.5).opacity(flash)
            }
            .shadow(color: Vibe.Palette.accentA.opacity(0.7 * flash), radius: 14)
            .allowsHitTesting(false))
        .scaleEffect(1 + 0.015 * flash)
        .onHover { hovering = $0 }
        .onChange(of: model.justMergedIDs) { _, ids in
            if ids.contains(entry.id) {
                flash = 1
                withAnimation(.easeOut(duration: 0.8)) { flash = 0 }
            }
        }
    }

    private var rowBackground: some View {
        RoundedRectangle(cornerRadius: 9).fill(
            selected ? Vibe.Palette.accentSoft(scheme)
            : hovering ? Vibe.Palette.surface2(scheme).opacity(0.6)
            : Color.clear)
    }

    // Visual-only checkbox (the whole-row Button handles the toggle). Revealed on
    // hover or whenever anything is selected ("selection mode").
    private var checkboxIndicator: some View {
        RoundedRectangle(cornerRadius: 6).fill(selected ? Vibe.Palette.accentA : .clear)
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(selected ? Vibe.Palette.accentA : Vibe.Palette.hairlineStrong(scheme), lineWidth: 1.6))
            .overlay(selected ? Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.white) : nil)
            .frame(width: 18, height: 18)
            .opacity(hovering || selected || !model.selection.isEmpty ? 1 : 0)
            .padding(.top, 2)
    }

    // Floating two-row action panel (revealed on hover): row 1 = 标签/复制/编辑/删除,
    // row 2 = 并入上一条/并入下一条 (only the applicable ones). An overlay so it never
    // adds row height or eats selection clicks at rest.
    private var actionsOverlay: some View {
        VStack(alignment: .trailing, spacing: 3) {
            HStack(spacing: 2) {
                HIconButton(symbol: "tag", size: 28, help: l10n.t("hist.tagmenu.tag")) { tagPop = true }
                    .popover(isPresented: $tagPop, arrowEdge: .bottom) {
                        TagMenu(ids: [entry.id], allTags: allTagNames) { model.applyTag([entry.id], $0); tagPop = false }
                    }
                HIconButton(symbol: "doc.on.doc", size: 28, help: l10n.t("copy")) { model.copy([entry.id], from: model.bridge.historyItems) }
                HIconButton(symbol: "pencil", size: 28, help: l10n.t("hist.act.edit")) { model.startEdit(entry) }
                HIconButton(symbol: "trash", danger: true, size: 28, help: l10n.t("delete")) { model.requestDelete([entry.id]) }
            }
            if canMergeUp || canMergeDown {
                HStack(spacing: 2) {
                    if canMergeUp { HIconButton(symbol: "arrow.up.to.line", size: 28, help: l10n.t("hist.act.mergeUp")) { model.mergeUp(entry.id, flatIds: flatIds) } }
                    if canMergeDown { HIconButton(symbol: "arrow.down.to.line", size: 28, help: l10n.t("hist.act.mergeDown")) { model.mergeDown(entry.id, flatIds: flatIds) } }
                }
            }
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Vibe.Palette.surface2(scheme)))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Vibe.Palette.hairline(scheme), lineWidth: 1))
        .shadow(color: .black.opacity(0.18), radius: 7, y: 3)
        .opacity(hovering ? 1 : 0)
        .allowsHitTesting(hovering)
        .padding(6)
    }

}

/// Pop-out, exclusive-focus editor (replaces the cramped inline box). Big
/// scrollable text area + optional note title + tag editor. Presented as a
/// `.sheet`, so its scrolling never fights the list behind it.
struct HistoryEditSheet: View {
    @ObservedObject var model: HistoryWorkspaceModel
    @ObservedObject var l10n: L10n = .shared
    let allTagNames: [String]
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(l10n.t("hist.edit.title")).font(Vibe.Fonts.ui(16, weight: .bold)).foregroundStyle(Vibe.Palette.text(scheme))
            TextEditor(text: $model.draftText)
                .font(Vibe.Fonts.mono(14)).scrollContentBackground(.hidden)
                .frame(maxWidth: .infinity, minHeight: 200, maxHeight: .infinity, alignment: .topLeading)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Vibe.Palette.surface(scheme)))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Vibe.Palette.accentA.opacity(0.45), lineWidth: 1))
            HStack(spacing: 6) {
                Image(systemName: "tag").font(.system(size: 12)).foregroundStyle(Vibe.Palette.textFaint(scheme))
                ForEach(model.draftTags, id: \.self) { t in TagChip(name: t, onRemove: { model.removeDraftTag(t) }) }
                TagAddField { model.addDraftTag($0) }
            }
            HStack(spacing: 8) {
                Text(l10n.t("hist.edit.hint")).font(Vibe.Fonts.ui(11)).foregroundStyle(Vibe.Palette.textFaint(scheme))
                Spacer()
                HBtn(title: l10n.t("cancel")) { model.cancelEdit() }.keyboardShortcut(.cancelAction)
                HBtn(title: l10n.t("hist.save"), system: "checkmark", kind: .accent) { model.commitEdit() }
                    .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(20).frame(width: 540, height: 460)
        .background(Vibe.Palette.surface2(scheme))
    }
}

/// Tiny "+ tag" input used in the editor.
private struct TagAddField: View {
    var onAdd: (String) -> Void
    @State private var text = ""
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        TextField(L10n.shared.t("hist.tag.add.ph"), text: $text)
            .textFieldStyle(.plain).font(Vibe.Fonts.ui(12))
            .frame(width: 90).padding(.horizontal, 10).frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 12).fill(Vibe.Palette.surface(scheme)))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [3]))
                .foregroundStyle(Vibe.Palette.hairlineStrong(scheme)))
            .onSubmit { onAdd(text); text = "" }
    }
}

// MARK: - Cluster wrapper

struct ClusterWrap<Content: View>: View {
    @ObservedObject var model: HistoryWorkspaceModel
    @ObservedObject var l10n: L10n = .shared
    let entries: [HistoryItem]      // ascending
    @ViewBuilder var content: () -> Content
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        let total = entries.reduce(0) { $0 + historyCharCount($1.text) }
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                HStack(spacing: 9) {
                    RoundedRectangle(cornerRadius: 2).strokeBorder(Vibe.Palette.accentA.opacity(0.5), lineWidth: 2)
                        .frame(width: 8, height: 8)
                    Text(l10n.t("hist.cluster.count", entries.count, total))
                        .font(Vibe.Fonts.ui(11.5, weight: .semibold)).foregroundStyle(Vibe.Palette.textMuted(scheme))
                    Text(l10n.t("hist.cluster.note")).font(Vibe.Fonts.ui(10.5)).foregroundStyle(Vibe.Palette.textFaint(scheme))
                }
                Spacer()
                HBtn(title: l10n.t("hist.cluster.merge"), system: "arrow.triangle.merge") {
                    model.merge(entries.map(\.id), asNote: false)
                }
            }
            .padding(.horizontal, 10).padding(.top, 6).padding(.bottom, 4)
            VStack(alignment: .leading, spacing: 0) { content() }
                .padding(.leading, 11)
                .overlay(alignment: .leading) { Rectangle().fill(Vibe.Palette.hairlineStrong(scheme)).frame(width: 2) }
                .padding(.leading, 9)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - OnCall fold

struct OnCallBlock<Content: View>: View {
    @ObservedObject var model: HistoryWorkspaceModel
    @ObservedObject var l10n: L10n = .shared
    let nodeId: String
    let entries: [HistoryItem]      // ascending
    @ViewBuilder var children: () -> Content
    @Environment(\.colorScheme) private var scheme
    private var expanded: Bool { model.expandedOC.contains(nodeId) }
    var body: some View {
        let total = entries.reduce(0) { $0 + historyCharCount($1.text) }
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Vibe.Palette.textMuted(scheme))
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                Text("OnCall").font(Vibe.Fonts.ui(9.5, weight: .bold)).foregroundStyle(Vibe.Palette.accentA)
                    .padding(.horizontal, 7).padding(.vertical, 1.5)
                    .background(Capsule().fill(Vibe.Palette.accentSoft(scheme)))
                Text(l10n.t("hist.oncall.count", entries.count, total))
                    .font(Vibe.Fonts.ui(12)).foregroundStyle(Vibe.Palette.textMuted(scheme))
                Spacer()
                if entries.count > 1 {
                    HBtn(title: l10n.t("hist.merge"), system: "arrow.triangle.merge") { model.merge(entries.map(\.id), asNote: false) }
                }
                HIconButton(symbol: "trash", danger: true, size: 28, help: l10n.t("hist.oncall.del")) { model.requestDelete(entries.map(\.id)) }
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .contentShape(Rectangle())
            .onTapGesture { model.toggleOC(nodeId) }

            if expanded {
                VStack(alignment: .leading, spacing: 0) { children() }
                    .padding(.horizontal, 10).padding(.bottom, 6)
                    .overlay(alignment: .top) { Rectangle().fill(Vibe.Palette.hairline(scheme)).frame(height: 1) }
            } else {
                Text((entries.first.map { String($0.text.prefix(54)) } ?? "") + l10n.t("hist.oncall.expand"))
                    .font(Vibe.Fonts.mono(13)).foregroundStyle(Vibe.Palette.textMuted(scheme))
                    .lineLimit(1).padding(.horizontal, 34).padding(.bottom, 11)
            }
        }
        .background(RoundedRectangle(cornerRadius: 10).fill(Vibe.Palette.surface2(scheme).opacity(0.5)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Vibe.Palette.hairline(scheme), lineWidth: 1))
        .padding(.vertical, 4)
    }
}

// MARK: - Aggregation popover

struct AggPopover: View {
    @ObservedObject var model: HistoryWorkspaceModel
    @ObservedObject var l10n: L10n = .shared
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            label(l10n.t("hist.agg.mode"))
            Picker("", selection: $model.aggMode) {
                Text(l10n.t("hist.agg.byPause")).tag(AggMode.pause)
                Text(l10n.t("hist.agg.byChars")).tag(AggMode.chars)
            }.pickerStyle(.segmented).labelsHidden()
            if model.aggMode == .pause {
                label(l10n.t("hist.agg.pauseHint"))
                Picker("", selection: $model.gapMin) {
                    ForEach([1, 2, 5, 10], id: \.self) { Text(l10n.t("hist.agg.minLabel", $0)).tag($0) }
                }.pickerStyle(.segmented).labelsHidden()
            } else {
                label(l10n.t("hist.agg.charsHint"))
                Picker("", selection: $model.targetChars) {
                    ForEach([60, 120, 200, 300], id: \.self) { Text(l10n.t("hist.agg.charLabel", $0)).tag($0) }
                }.pickerStyle(.segmented).labelsHidden()
            }
        }
        .padding(13).frame(width: 260)
    }
    private func label(_ t: String) -> some View {
        Text(t).font(Vibe.Fonts.ui(11.5, weight: .semibold)).foregroundStyle(Vibe.Palette.textMuted(scheme))
    }
}

// MARK: - Tag menu (popover content)

struct TagMenu: View {
    let ids: [UUID]
    let allTags: [String]
    let onApply: (String) -> Void
    @State private var val = ""
    @ObservedObject var l10n: L10n = .shared
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(l10n.t("hist.tagmenu.title", ids.count)).font(Vibe.Fonts.ui(11.5, weight: .bold))
                .foregroundStyle(Vibe.Palette.textMuted(scheme))
            HStack(spacing: 7) {
                Image(systemName: "tag").font(.system(size: 12)).foregroundStyle(Vibe.Palette.textFaint(scheme))
                TextField(l10n.t("hist.tagmenu.ph"), text: $val).textFieldStyle(.plain).font(Vibe.Fonts.ui(13))
                    .onSubmit { if !val.trimmingCharacters(in: .whitespaces).isEmpty { onApply(val); val = "" } }
            }
            .padding(.horizontal, 9).frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 8).fill(Vibe.Palette.surface(scheme)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Vibe.Palette.hairline(scheme), lineWidth: 1))
            let matches = allTags.filter { val.isEmpty || $0.localizedCaseInsensitiveContains(val) }
            if matches.isEmpty && allTags.isEmpty {
                Text(l10n.t("hist.tagmenu.empty")).font(Vibe.Fonts.ui(12)).foregroundStyle(Vibe.Palette.textFaint(scheme))
            } else {
                VStack(spacing: 2) {
                    ForEach(matches, id: \.self) { t in
                        Button { onApply(t) } label: {
                            HStack(spacing: 8) {
                                Circle().fill(historyTagColor(t)).frame(width: 6, height: 6)
                                Text(t).font(Vibe.Fonts.ui(13)).foregroundStyle(Vibe.Palette.text(scheme))
                                Spacer()
                            }.padding(.horizontal, 8).frame(height: 30).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }.frame(maxHeight: 190)
            }
        }
        .padding(11).frame(width: 220)
    }
}

// MARK: - Bulk bar (floating)

struct BulkBar: View {
    @ObservedObject var model: HistoryWorkspaceModel
    @ObservedObject var l10n: L10n = .shared
    let entries: [HistoryItem]
    let allTagNames: [String]
    @Environment(\.colorScheme) private var scheme
    @State private var tagPop = false
    var body: some View {
        let ids = Array(model.selection)
        HStack(spacing: 6) {
            HStack(spacing: 8) {
                Text("\(model.selection.count)").font(Vibe.Fonts.ui(12, weight: .bold)).foregroundStyle(.white)
                    .frame(minWidth: 22, minHeight: 22).background(Circle().fill(Vibe.Palette.accentA))
                Text(l10n.t("hist.selected")).font(Vibe.Fonts.ui(13, weight: .bold)).foregroundStyle(Vibe.Palette.text(scheme))
            }.padding(.leading, 4)
            divider
            HBtn(title: l10n.t("hist.merge"), system: "arrow.triangle.merge", disabled: model.selection.count < 2) { model.merge(ids, asNote: false) }
            HBtn(title: l10n.t("hist.tagmenu.tag"), system: "tag") { tagPop = true }
                .popover(isPresented: $tagPop, arrowEdge: .top) {
                    TagMenu(ids: ids, allTags: allTagNames) { model.applyTag(ids, $0); tagPop = false }
                }
            HBtn(title: l10n.t("copy"), system: "doc.on.doc") { model.copy(ids, from: entries) }
            HBtn(title: l10n.t("hist.export"), system: "square.and.arrow.up") { model.exportItems(entries.filter { model.selection.contains($0.id) }) }
            divider
            HBtn(title: l10n.t("delete"), system: "trash", kind: .danger) { model.requestDelete(ids) }
            HIconButton(symbol: "xmark", size: 28, help: l10n.t("hist.bulk.clear")) { model.clearSelection() }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 12).fill(Vibe.Palette.surface2(scheme)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Vibe.Palette.hairlineStrong(scheme), lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 18, y: 10)
    }
    private var divider: some View { Rectangle().fill(Vibe.Palette.hairlineStrong(scheme)).frame(width: 1, height: 22) }
}

// MARK: - Toast

struct ToastBar: View {
    @ObservedObject var model: HistoryWorkspaceModel
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        if let msg = model.toast {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 13)).foregroundStyle(Vibe.Palette.success)
                Text(msg).font(Vibe.Fonts.ui(13)).foregroundStyle(Vibe.Palette.text(scheme))
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 10).fill(Vibe.Palette.surface2(scheme)))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Vibe.Palette.hairlineStrong(scheme), lineWidth: 1))
            .shadow(color: .black.opacity(0.3), radius: 14, y: 8)
            .transition(.opacity)
        }
    }
}
