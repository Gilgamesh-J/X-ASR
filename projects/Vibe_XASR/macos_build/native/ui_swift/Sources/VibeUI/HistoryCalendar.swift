// ============================================================
//  Vibe XASR — History calendar (mini rail + month heatmap)
//  Recreates calendar.jsx in SwiftUI, adaptive light/dark via Vibe.Palette.
// ============================================================

import SwiftUI

/// Monday-first short weekday names, localized. Cocoa weekday 1=Sun … 7=Sat;
/// `weekdayShort` takes 0=Sun … 6=Sat, so Monday-first order is [1,2,3,4,5,6,0].
@MainActor private var kWeekdays: [String] {
    [1, 2, 3, 4, 5, 6, 0].map { L10n.shared.weekdayShort($0) }
}
private let kCalCols = Array(repeating: GridItem(.flexible(), spacing: 2), count: 7)

/// Month title + prev / 今天 / next navigation, shared by mini + heatmap.
struct MonthHeaderView: View {
    @Binding var cursor: Date
    @ObservedObject var l10n: L10n = .shared
    @Environment(\.colorScheme) private var scheme
    private let cal = Calendar.current

    private func shift(_ months: Int) {
        if let d = cal.date(byAdding: .month, value: months, to: cursor) { cursor = d }
    }
    var body: some View {
        let c = cal.dateComponents([.year, .month], from: cursor)
        HStack {
            Text(l10n.t("hist.cal.month", String(c.year ?? 0), c.month ?? 0))
                .font(Vibe.Fonts.ui(13.5, weight: .bold))
                .foregroundStyle(Vibe.Palette.text(scheme))
            Spacer()
            HStack(spacing: 2) {
                navBtn("chevron.left") { shift(-1) }
                Button { cursor = Date() } label: {
                    Text(l10n.t("hist.today")).font(Vibe.Fonts.ui(11))
                        .foregroundStyle(Vibe.Palette.textMuted(scheme))
                        .padding(.horizontal, 8).frame(height: 24)
                }.buttonStyle(.plain)
                navBtn("chevron.right") { shift(1) }
            }
        }
        .padding(.bottom, 10)
    }
    private func navBtn(_ sym: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: sym).font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Vibe.Palette.textMuted(scheme))
                .frame(width: 24, height: 24)
        }.buttonStyle(.plain)
    }
}

private struct WeekdayRow: View {
    @ObservedObject var l10n: L10n = .shared
    @Environment(\.colorScheme) private var scheme
    var big = false
    var body: some View {
        LazyVGrid(columns: kCalCols, spacing: 0) {
            ForEach(kWeekdays, id: \.self) { w in
                Text(w).font(Vibe.Fonts.ui(big ? 12 : 10.5, weight: .semibold))
                    .foregroundStyle(Vibe.Palette.textFaint(scheme))
                    .frame(maxWidth: .infinity).padding(.vertical, big ? 6 : 3)
            }
        }
    }
}

// MARK: - Mini calendar (rail)

struct MiniCalendar: View {
    let counts: [String: Int]
    let selected: String?
    let todayKey: String
    let onSelect: (String?) -> Void
    @State private var cursor = Date()
    @Environment(\.colorScheme) private var scheme
    private let cal = Calendar.current

    var body: some View {
        VStack(spacing: 4) {
            MonthHeaderView(cursor: $cursor)
            WeekdayRow()
            LazyVGrid(columns: kCalCols, spacing: 2) {
                ForEach(Array(historyMonthGrid(cursor, cal).enumerated()), id: \.offset) { _, d in
                    cell(d)
                }
            }
        }
    }

    @ViewBuilder private func cell(_ d: Date) -> some View {
        let k = historyDayKey(d, cal)
        let n = counts[k] ?? 0
        let out = cal.component(.month, from: d) != cal.component(.month, from: cursor)
        let isSel = k == selected
        let isToday = k == todayKey
        Button { onSelect(n > 0 ? k : nil) } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isSel ? Vibe.Palette.accentA : .clear)
                if isToday, !isSel {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(Vibe.Palette.accentA.opacity(0.5), lineWidth: 1.5)
                }
                Text("\(cal.component(.day, from: d))")
                    .font(Vibe.Fonts.mono(12))
                    .foregroundStyle(isSel ? .white
                        : out ? Vibe.Palette.textFaint(scheme).opacity(0.55)
                        : n > 0 ? Vibe.Palette.text(scheme) : Vibe.Palette.textMuted(scheme))
                if n > 0, !isSel {
                    Circle().fill(Vibe.Palette.accentA.opacity(min(1, 0.35 + Double(n) / 10)))
                        .frame(width: 4, height: 4)
                        .offset(y: 9)
                }
            }
            .frame(maxWidth: .infinity).aspectRatio(1, contentMode: .fit)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(out)
    }
}

// MARK: - Month heatmap (full view)

struct MonthHeatmap: View {
    let counts: [String: Int]
    let selected: String?
    let todayKey: String
    let onSelect: (String?) -> Void
    @State private var cursor = Date()
    @Environment(\.colorScheme) private var scheme
    private let cal = Calendar.current

    private func bg(_ lvl: Int) -> Color {
        switch lvl {
        case 1: return Vibe.Palette.accentA.opacity(0.16)
        case 2: return Vibe.Palette.accentA.opacity(0.32)
        case 3: return Vibe.Palette.accentA.opacity(0.55)
        case 4: return Vibe.Palette.accentA.opacity(0.85)
        default: return Vibe.Palette.surface2(scheme)
        }
    }
    private func fg(_ lvl: Int) -> Color {
        switch lvl {
        case 0: return Vibe.Palette.textFaint(scheme)
        case 1: return Vibe.Palette.textMuted(scheme)
        case 2: return Vibe.Palette.text(scheme)
        default: return .white
        }
    }

    var body: some View {
        let maxN = max(1, counts.values.max() ?? 1)
        VStack(alignment: .leading, spacing: 4) {
            MonthHeaderView(cursor: $cursor)
            WeekdayRow(big: true)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 5), count: 7), spacing: 5) {
                ForEach(Array(historyMonthGrid(cursor, cal).enumerated()), id: \.offset) { _, d in
                    cell(d, maxN: maxN)
                }
            }
            legend
        }
        .frame(maxWidth: 560, alignment: .leading)
    }

    @ViewBuilder private func cell(_ d: Date, maxN: Int) -> some View {
        let k = historyDayKey(d, cal)
        let n = counts[k] ?? 0
        let out = cal.component(.month, from: d) != cal.component(.month, from: cursor)
        let isSel = k == selected
        let isToday = k == todayKey
        let lvl = historyHeatLevel(n, max: maxN)
        Button { onSelect(n > 0 ? k : nil) } label: {
            VStack(alignment: .leading, spacing: 0) {
                Text("\(cal.component(.day, from: d))")
                    .font(Vibe.Fonts.mono(12, weight: .semibold)).foregroundStyle(fg(lvl))
                Spacer(minLength: 0)
                if n > 0 {
                    Text("\(n)").font(Vibe.Fonts.mono(11, weight: .bold))
                        .foregroundStyle(fg(lvl)).frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .frame(maxWidth: .infinity).aspectRatio(1.15, contentMode: .fit)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(bg(lvl)))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(isToday ? Vibe.Palette.accentA
                    : isSel ? Color.primary
                    : Vibe.Palette.hairline(scheme), lineWidth: isToday || isSel ? 2 : 1))
            .opacity(out ? 0.25 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(out || n == 0)
    }

    private var legend: some View {
        HStack(spacing: 5) {
            Spacer()
            Text(L10n.shared.t("hist.heat.less")).font(Vibe.Fonts.ui(11)).foregroundStyle(Vibe.Palette.textFaint(scheme))
            ForEach(0..<5, id: \.self) { l in
                RoundedRectangle(cornerRadius: 4).fill(bg(l)).frame(width: 14, height: 14)
            }
            Text(L10n.shared.t("hist.heat.more")).font(Vibe.Fonts.ui(11)).foregroundStyle(Vibe.Palette.textFaint(scheme))
        }
        .padding(.top, 14)
    }
}
