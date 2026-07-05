// ============================================================
//  Vibe XASR — Menu-bar dropdown content
//  Faithful port of ui/menubar.html.
//  Status row (colored dot + state + sub) · optional working progress ·
//  最近一条 recent card (live caret while listening) · 启用听写 toggle ·
//  设置 / 帮助 / 退出 entries.
// ============================================================

import SwiftUI

@MainActor
public final class MenuBarState: ObservableObject {
    public enum Status: String, Sendable {
        case idle        // 就绪
        case listening   // 聆听中…
        case working     // 整理中
    }
    @Published public var status: Status = .idle
    @Published public var enabled = true
    /// Last recognized line (shown when not actively listening).
    @Published public var recent = "明天下午三点和产品团队开会，地点改到二号会议室。"
    /// Live partial shown while listening.
    @Published public var livePartial = "请把这段整理成一条更清晰的会议提醒"
    /// Progress fraction (0...1) shown while working.
    @Published public var workProgress = 0.64
    public init() {}
}

public struct MenuBarContentView: View {
    @ObservedObject var state: MenuBarState
    @Environment(\.colorScheme) private var scheme

    public init(state: MenuBarState) {
        self.state = state
    }

    public init() {
        self.state = MenuBarState()
    }

    private var statusText: String {
        switch state.status {
        case .idle:      return "准备就绪"
        case .listening: return "正在聆听…"
        case .working:   return "正在整理"
        }
    }
    private var subText: String {
        state.status == .working ? "请稍候，文本正在完成整理" : "本地语音输入已就绪"
    }

    public var body: some View {
        VStack(spacing: 0) {
            statusRow
            if state.status == .working { workProgressRow }
            separator
            recentSection
            separator
            enableToggleRow
            separator
            entries
        }
        .frame(width: 296)
        .glassPanel(cornerRadius: 14)
    }

    // ----- status -----------------------------------------------------

    private var statusRow: some View {
        HStack(spacing: 10) {
            StatusDot(status: state.status)
            VStack(alignment: .leading, spacing: 1) {
                Text(statusText)
                    .font(Vibe.Fonts.ui(13.5, weight: .semibold))
                    .foregroundStyle(Vibe.Palette.text(scheme))
                Text(subText)
                    .font(Vibe.Fonts.mono(11))
                    .foregroundStyle(Vibe.Palette.textMuted(scheme))
            }
            Spacer()
        }
        .padding(.top, 14).padding(.bottom, 12).padding(.horizontal, 16)
    }

    private var workProgressRow: some View {
        HStack(spacing: 9) {
            ProgressBar(fraction: state.workProgress)
            Text("\(Int(state.workProgress * 100))%")
                .font(Vibe.Fonts.mono(11))
                .foregroundStyle(Vibe.Palette.textMuted(scheme))
        }
        .padding(.top, 4).padding(.bottom, 12).padding(.horizontal, 16)
    }

    // ----- recent -----------------------------------------------------

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("最近输入")
                .font(Vibe.Fonts.mono(10.5)).tracking(0.8)
                .textCase(.uppercase)
                .foregroundStyle(Vibe.Palette.textMuted(scheme))
            recentCard
        }
        .padding(.vertical, 12).padding(.horizontal, 16)
    }

    @ViewBuilder
    private var recentCard: some View {
        if state.status == .listening {
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text(state.livePartial)
                    .font(Vibe.Fonts.mono(12))
                    .foregroundStyle(Vibe.Palette.text(scheme))
                MenuCaret()
                Spacer(minLength: 0)
            }
            .padding(.vertical, 10).padding(.horizontal, 12)
            .background(recentBackground)
        } else {
            HStack(alignment: .top, spacing: 8) {
                Text(state.recent)
                    .font(Vibe.Fonts.mono(12))
                    .foregroundStyle(Vibe.Palette.text(scheme))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Text("复制")
                    .font(Vibe.Fonts.ui(11))
                    .foregroundStyle(Vibe.Palette.textMuted(scheme))
            }
            .padding(.vertical, 10).padding(.horizontal, 12)
            .background(recentBackground)
        }
    }

    private var recentBackground: some View {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(Vibe.Palette.surface2(scheme))
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(Vibe.Palette.hairline(scheme), lineWidth: 1)
            )
    }

    // ----- enable toggle ----------------------------------------------

    private var enableToggleRow: some View {
        HStack {
            Text("启用语音输入")
                .font(Vibe.Fonts.ui(13))
                .foregroundStyle(Vibe.Palette.text(scheme))
            Spacer()
            MenuSwitch(on: $state.enabled)
        }
        .padding(.vertical, 11).padding(.horizontal, 16)
    }

    // ----- entries ----------------------------------------------------

    private var entries: some View {
        VStack(spacing: 0) {
            MenuEntry(icon: "⚙", title: "设置…", shortcut: "⌘,")
            MenuEntry(icon: "?", title: "使用帮助")
            MenuEntry(icon: "⏻", title: "退出", shortcut: "⌘Q", destructive: true)
        }
        .padding(6)
    }

    private var separator: some View {
        Rectangle()
            .fill(Vibe.Palette.hairline(scheme))
            .frame(height: 1)
            .padding(.horizontal, 12)
    }
}

// MARK: - Pieces

/// `.st-dot` — green idle / pinging accent listening / amber working.
private struct StatusDot: View {
    var status: MenuBarState.Status
    @State private var ping = false
    private var color: Color {
        switch status {
        case .idle:      return Vibe.Palette.success
        case .listening: return Vibe.Palette.accentA
        case .working:   return Vibe.Palette.warn
        }
    }
    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 9, height: 9)
            .overlay(
                Circle()
                    .stroke(Vibe.Palette.accentA.opacity(status == .listening ? (ping ? 0 : 0.5) : 0),
                            lineWidth: status == .listening ? (ping ? 8 : 0) : 0)
                    .scaleEffect(status == .listening && ping ? 2.6 : 1)
            )
            .onAppear { if status == .listening { animatePing() } }
            .onChange(of: status) { s in if s == .listening { animatePing() } else { ping = false } }
    }
    private func animatePing() {
        ping = false
        withAnimation(.easeOut(duration: 1.2).repeatForever(autoreverses: false)) {
            ping = true
        }
    }
}

/// `.sw` toggle sized for the menu (40×24).
private struct MenuSwitch: View {
    @Environment(\.colorScheme) private var scheme
    @Binding var on: Bool
    var body: some View {
        Button {
            withAnimation(Vibe.Motion.spring) { on.toggle() }
        } label: {
            ZStack(alignment: on ? .trailing : .leading) {
                Capsule()
                    .fill(on
                          ? AnyShapeStyle(Vibe.accentGradient)
                          : AnyShapeStyle(Vibe.Palette.surface2(scheme)))
                    .frame(width: 40, height: 24)
                Circle()
                    .fill(Color.white)
                    .frame(width: 19, height: 19)
                    .shadow(color: .black.opacity(0.3), radius: 1.5, y: 1)
                    .padding(.horizontal, 2.5)
            }
        }
        .buttonStyle(.plain)
    }
}

/// `.entry` — icon + label, optional trailing shortcut; destructive (quit) red on hover.
private struct MenuEntry: View {
    @Environment(\.colorScheme) private var scheme
    var icon: String
    var title: String
    var shortcut: String? = nil
    var destructive: Bool = false
    @State private var hovering = false
    var body: some View {
        Button {} label: {
            HStack(spacing: 10) {
                Text(icon)
                    .frame(width: 16)
                    .opacity(0.8)
                    .foregroundStyle(destructive && hovering
                                     ? Vibe.Palette.error : Vibe.Palette.text(scheme))
                Text(title)
                    .font(Vibe.Fonts.ui(13))
                    .foregroundStyle(destructive && hovering
                                     ? Vibe.Palette.error : Vibe.Palette.text(scheme))
                Spacer()
                if let shortcut {
                    Text(shortcut)
                        .font(Vibe.Fonts.mono(11))
                        .foregroundStyle(Vibe.Palette.textMuted(scheme))
                }
            }
            .padding(.vertical, 8).padding(.horizontal, 10)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(hovering
                          ? (destructive
                             ? Vibe.Palette.error.opacity(0.16)
                             : Vibe.Palette.accentSoft(scheme))
                          : .clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Live caret used inside the menu's listening card.
private struct MenuCaret: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
            let on = Int(ctx.date.timeIntervalSinceReferenceDate / 0.5) % 2 == 0
            Text("▌")
                .font(Vibe.Fonts.mono(12))
                .foregroundStyle(Vibe.Palette.accentB)
                .opacity(on ? 1 : 0)
        }
    }
}

// MARK: - Preview (dark)

#Preview("MenuBar · idle (dark)") {
    MenuBarContentView(state: MenuBarState())
        .padding(40)
        .background(Color(hex: "#0E0E12"))
        .preferredColorScheme(.dark)
}

#Preview("MenuBar · listening (dark)") {
    let s = MenuBarState()
    s.status = .listening
    return MenuBarContentView(state: s)
        .padding(40)
        .background(Color(hex: "#0E0E12"))
        .preferredColorScheme(.dark)
}

#Preview("MenuBar · working (dark)") {
    let s = MenuBarState()
    s.status = .working
    return MenuBarContentView(state: s)
        .padding(40)
        .background(Color(hex: "#0E0E12"))
        .preferredColorScheme(.dark)
}
