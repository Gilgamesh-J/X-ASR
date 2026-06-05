// ============================================================
//  Vibe XASR — HUD surface (compact pill + expanded + radical)
//  Faithful port of ui/assets/hud.jsx + the <style> block in hud.html.
//
//  Left   : audio-reactive Waveform (center-weighted) behind a state Orb.
//  Middle : monospaced streaming text + blinking caret "▌" (.speaking)
//           or "…" (.pause); placeholder "在听…" while .empty.
//  Right  : mm:ss timer (listening) / "已插入" (done) / "已取消" (cancel)
//           / "去设置" button (error).
// ============================================================

import SwiftUI

// MARK: - Waveform (center-weighted, 60fps amplitude follower)

/// Mirrors the JSX `Waveform`: N bars whose smoothed heights ease toward a
/// center-weighted envelope of `level`. Driven by a TimelineView at ~60fps.
public struct Waveform: View {
    @Environment(\.colorScheme) private var scheme
    var level: Double
    var phase: HUDModel.Phase
    var bars: Int
    var big: Bool

    // Per-bar smoothed heights (retained across frames).
    @State private var smooth: [Double]
    // Per-bar random jitter, refreshed each frame for organic motion.
    @State private var seeds: [Double]

    public init(level: Double, phase: HUDModel.Phase, bars: Int, big: Bool = false) {
        self.level = level
        self.phase = phase
        self.bars = bars
        self.big = big
        _smooth = State(initialValue: Array(repeating: 0.1, count: bars))
        _seeds = State(initialValue: (0..<bars).map { _ in Double.random(in: 0...1) })
        _heights = State(initialValue: Array(repeating: 0.1, count: bars))
    }

    private var barWidth: CGFloat { big ? 3 : 2 }
    private var gap: CGFloat { big ? 3 : 2 }
    private var trackHeight: CGFloat { big ? 150 : 26 }
    private var trackWidth: CGFloat { big ? 150 : 40 }

    // Hidden during finalize/done/cancel (waveform fades out in the JSX).
    private var hidden: Bool {
        phase == .finalizing || phase == .done || phase == .cancel
    }

    public var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { ctx, size in
                guard bars > 0 else { return }
                let n = bars
                let totalGaps = CGFloat(n - 1) * gap
                let usableW = size.width
                let startX = (usableW - (CGFloat(n) * barWidth + totalGaps)) / 2
                for i in 0..<min(n, heights.count) {
                    let h = heights[i]
                    let barH = max(2, CGFloat(h) * size.height)
                    let x = startX + CGFloat(i) * (barWidth + gap)
                    let y = (size.height - barH) / 2
                    let rect = CGRect(x: x, y: y, width: barWidth, height: barH)
                    let path = Path(roundedRect: rect, cornerRadius: barWidth / 2)
                    // linear-gradient(180deg, accent-a, accent-b)
                    ctx.fill(path, with: .linearGradient(
                        Gradient(colors: [Vibe.Palette.accentA, Vibe.Palette.accentB]),
                        startPoint: CGPoint(x: rect.midX, y: rect.minY),
                        endPoint: CGPoint(x: rect.midX, y: rect.maxY)))
                }
            }
            .frame(width: trackWidth, height: trackHeight)
            // Advance the simulation on every timeline tick.
            .onChange(of: timeline.date) { _ in step() }
        }
        .opacity(hidden ? 0 : 1)
        .animation(.easeOut(duration: 0.2), value: hidden)
    }

    // Snapshot used for drawing (kept in @State so Canvas redraws).
    @State private var heights: [Double] = []

    private func step() {
        let n = bars
        if smooth.count != n { smooth = Array(repeating: 0.1, count: n) }
        if heights.count != n { heights = Array(repeating: 0.1, count: n) }
        let mid = Double(n - 1) / 2
        var next = smooth
        for i in 0..<n {
            // center-weighted envelope: middle bars tallest
            let c = 1 - abs(Double(i) - mid) / max(mid, 0.0001)
            let env = 0.35 + 0.65 * c
            let target: Double
            switch phase {
            case .speaking:
                target = level * env * (0.45 + Double.random(in: 0...0.75))
            case .pause, .empty:
                target = 0.06 + Double.random(in: 0...0.03) // flatten to a thin line
            default:
                target = 0.05
            }
            next[i] += (target - next[i]) * 0.35   // ease toward target
            next[i] = min(1, max(0.05, next[i]))
        }
        smooth = next
        heights = next
    }
}

// MARK: - Orb (state light / ✓ / ✕ / error glyph)

/// Mirrors the JSX `Orb`: an accent sphere that breathes while speaking,
/// turns green ✓ on done, red ✕ on cancel, red glyph on error.
public struct Orb: View {
    @Environment(\.colorScheme) private var scheme
    var phase: HUDModel.Phase
    var errorIcon: String?
    var big: Bool

    public init(phase: HUDModel.Phase, errorIcon: String? = nil, big: Bool = false) {
        self.phase = phase
        self.errorIcon = errorIcon
        self.big = big
    }

    private var size: CGFloat { big ? 52 : 28 }
    private var glyphSize: CGFloat { big ? 24 : 15 }

    private var fill: AnyShapeStyle {
        switch phase {
        case .finalizing, .done: return AnyShapeStyle(Vibe.Palette.success)
        case .cancel, .error:    return AnyShapeStyle(Vibe.Palette.error)
        default:                 return AnyShapeStyle(Vibe.accentGradient)
        }
    }

    private var glowColor: Color {
        switch phase {
        case .finalizing, .done: return Vibe.Palette.success.opacity(0.6)
        case .cancel:            return Vibe.Palette.error.opacity(0.55)
        case .error:             return Vibe.Palette.error.opacity(0.6)
        default:                 return Vibe.Palette.accentA.opacity(0.5)
        }
    }

    public var body: some View {
        ZStack {
            Circle()
                .fill(fill)
                .frame(width: size, height: size)
                .shadow(color: glowColor, radius: phase == .speaking ? 13 : 11)
                // breathe: 1.2s ease-in-out pulse while live
                .modifier(BreatheModifier(active: phase == .speaking))

            switch phase {
            case .finalizing, .done:
                Text("✓").font(.system(size: glyphSize, weight: .bold)).foregroundStyle(.white)
            case .cancel:
                Text("✕").font(.system(size: glyphSize, weight: .bold)).foregroundStyle(.white)
            case .error:
                Text(errorIcon ?? "!")
                    .font(.system(size: big ? 22 : 14, weight: .bold))
                    .foregroundStyle(.white)
            default:
                EmptyView()
            }
        }
        .frame(width: size, height: size)
    }
}

/// `@keyframes breathe` — a soft 1.2s scale/glow pulse while speaking.
private struct BreatheModifier: ViewModifier {
    var active: Bool
    @State private var pulse = false
    func body(content: Content) -> some View {
        content
            .scaleEffect(active && pulse ? 1.06 : 1.0)
            .shadow(color: active
                    ? Vibe.Palette.accentB.opacity(pulse ? 0.7 : 0.0)
                    : .clear,
                    radius: active ? (pulse ? 16 : 8) : 0)
            .onAppear { if active { animate() } }
            .onChange(of: active) { on in if on { animate() } else { pulse = false } }
    }
    private func animate() {
        withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
            pulse = true
        }
    }
}

// MARK: - Polishing spinner (云端/本地大模型润色中的动态球)

/// 润色等待时的动态指示:accent 球轻微呼吸 + 一圈白色弧线匀速旋转 + ✨,既"在动"又不喧宾夺主。
private struct PolishingSpinner: View {
    @State private var spin = false
    @State private var pulse = false
    var body: some View {
        ZStack {
            Circle().fill(Vibe.accentGradient)
                .frame(width: 28, height: 28)
                .shadow(color: Vibe.Palette.accentA.opacity(pulse ? 0.65 : 0.35), radius: pulse ? 14 : 9)
                .scaleEffect(pulse ? 1.05 : 1.0)
            Circle().trim(from: 0, to: 0.72)
                .stroke(Color.white.opacity(0.92), style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
                .frame(width: 19, height: 19)
                .rotationEffect(.degrees(spin ? 360 : 0))
            Text("✨").font(.system(size: 10))
        }
        .frame(width: 28, height: 28)
        .onAppear {
            withAnimation(.linear(duration: 0.85).repeatForever(autoreverses: false)) { spin = true }
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { pulse = true }
        }
    }
}

// MARK: - Blinking caret "▌" / pause dots "…"

/// `.cursor` / `.caret`: accent-b "▌" blinking at 1s step-end.
/// Driven by a TimelineView so it needs no Timer and stays MainActor-clean.
private struct BlinkingCaret: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
            // step-end: visible for the first half of each 1s period, hidden the second.
            let t = ctx.date.timeIntervalSinceReferenceDate
            let on = Int(t / 0.5) % 2 == 0
            Text("▌")
                .foregroundStyle(Vibe.Palette.accentB)
                .opacity(on ? 1 : 0)
        }
    }
}

// MARK: - Compact HUD pill

/// The default compact HUD pill. Binds to an external `HUDModel`.
public struct HUDView: View {
    @ObservedObject var model: HUDModel
    @ObservedObject private var l10n = L10n.shared
    @Environment(\.colorScheme) private var scheme
    public var form: HUDModel.Form

    public init(model: HUDModel, form: HUDModel.Form = .compact) {
        self.model = model
        self.form = form
    }

    private var barCount: Int {
        switch form {
        case .radical:  return 36
        case .expanded: return 30
        case .compact:  return 24
        }
    }

    public var body: some View {
        Group {
            switch form {
            case .radical:  radicalBody
            default:        capsuleBody   // compact + expanded share the capsule
            }
        }
        .opacity(model.phase.isVisible ? 1 : 0)
        .scaleEffect(model.phase.isVisible ? 1 : 0.98)
        .offset(y: model.phase.isVisible ? 0 : 10)
        .animation(Vibe.Motion.easeOut, value: model.phase.isVisible)
        .animation(Vibe.Motion.spring, value: model.phase) // bounceIn on phase change
    }

    // ----- compact / expanded capsule ---------------------------------

    private var capsuleBody: some View {
        let isExpanded = form == .expanded
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: isExpanded ? .top : .center, spacing: Vibe.Space.s3) {
                leftCluster
                midText(expanded: isExpanded)
                if !isExpanded { Spacer(minLength: 8) }
                rightStatus
            }
            if model.phase == .polishing, let hint = model.polishHint {
                Text(hint)
                    .font(Vibe.Fonts.ui(11))
                    .foregroundStyle(Vibe.Palette.textMuted(scheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if isExpanded, model.phase != .error, !model.partialText.isEmpty {
                expandedBar
            }
        }
        .padding(.vertical, isExpanded ? 14 : 12)
        .padding(.horizontal, isExpanded ? 18 : 16)
        .frame(minWidth: 280, maxWidth: isExpanded ? 560 : 620, alignment: .leading)
        .glassPanel(cornerRadius: isExpanded ? 22 : Vibe.Radius.pill,
                    glow: model.phase == .cancel ? Vibe.Palette.error : nil,
                    glowRadius: model.phase == .cancel ? 2 : 0,
                    shadow: false)   // 浮窗只要圆角,不要阴影(用户要求)
        // cancel form gets a 2px error ring (box-shadow ... 0 0 0 2px error)
        .overlay(
            Group {
                if model.phase == .cancel {
                    RoundedRectangle(cornerRadius: isExpanded ? 22 : Vibe.Radius.pill,
                                     style: .continuous)
                        .strokeBorder(Vibe.Palette.error, lineWidth: 2)
                }
            }
        )
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Left: orb with a waveform behind it while listening; bare orb on error.
    private var leftCluster: some View {
        ZStack {
            if model.phase != .error, model.phase.isListening {
                Waveform(level: model.level, phase: model.phase, bars: barCount)
            }
            if model.phase == .polishing {
                PolishingSpinner()
            } else {
                Orb(phase: model.phase, errorIcon: model.errorInfo?.icon)
            }
        }
        .frame(width: 40, height: 40)
    }

    /// Middle: error block, or the streaming monospaced line + caret/dots.
    @ViewBuilder
    private func midText(expanded: Bool) -> some View {
        if model.phase == .error {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.errorInfo?.title ?? "")
                    .font(Vibe.Fonts.ui(13.5, weight: .semibold))
                    .foregroundStyle(Vibe.Palette.text(scheme))
                Text(model.errorInfo?.reason ?? "")
                    .font(Vibe.Fonts.ui(12))
                    .foregroundStyle(Vibe.Palette.textMuted(scheme))
            }
            .frame(maxWidth: expanded ? .infinity : nil, alignment: .leading)
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                streamingText
                if model.phase == .speaking { BlinkingCaret() }
                if model.phase == .pause {
                    Text("…")
                        .font(Vibe.Fonts.mono(14))
                        .foregroundStyle(Vibe.Palette.textMuted(scheme))
                        .tracking(2)
                }
            }
            .lineLimit(expanded ? nil : 1)
            .frame(maxWidth: expanded ? .infinity : 460, alignment: .leading)
        }
    }

    private var streamingText: some View {
        // .empty → listening placeholder in muted color.
        let isPlaceholder = model.phase == .empty || model.partialText.isEmpty
        let shown = model.phase == .empty ? l10n.t("hud.listening")
                  : (model.partialText.isEmpty ? "" : model.partialText)
        return Text(shown)
            .font(Vibe.Fonts.mono(14))
            .foregroundStyle(isPlaceholder
                             ? Vibe.Palette.textMuted(scheme)
                             : Vibe.Palette.text(scheme))
            // Truncate from the HEAD so the NEWEST words stay visible as the line
            // grows (the stream keeps flowing on the right instead of clipping it).
            .truncationMode(.head)
    }

    /// Expanded action bar: copy-all + a hint line.
    private var expandedBar: some View {
        HStack(spacing: 12) {
            Text(l10n.t("hud.copyAll"))
                .font(Vibe.Fonts.ui(12))
                .foregroundStyle(Vibe.Palette.text(scheme))
                .padding(.vertical, 5).padding(.horizontal, 12)
                .background(
                    Capsule().fill(Vibe.Palette.surface2(scheme))
                )
                .overlay(Capsule().strokeBorder(Vibe.Palette.hairline(scheme), lineWidth: 1))
            Text(model.phase == .done ? l10n.t("hud.insertedAt") : l10n.t("hud.releaseHint"))
                .font(Vibe.Fonts.mono(11))
                .foregroundStyle(Vibe.Palette.textMuted(scheme))
        }
        .padding(.leading, 0)
    }

    /// Right: timer / 已插入 / 已取消 / 去设置.
    @ViewBuilder
    private var rightStatus: some View {
        switch model.phase {
        case .empty, .speaking, .pause:
            Text(model.elapsed)
                .font(Vibe.Fonts.mono(12.5))
                .foregroundStyle(Vibe.Palette.textMuted(scheme))
                .padding(.vertical, 4).padding(.horizontal, 9)
                .background(Capsule().fill(Vibe.Palette.surface2(scheme)))
        case .finalizing, .done:
            Text(l10n.t("hud.inserted"))
                .font(Vibe.Fonts.ui(12.5, weight: .semibold))
                .foregroundStyle(Vibe.Palette.success)
        case .polishing:
            if model.polishSlow {
                // 等久了:给「立即插入 ✓」——用规则版立即插入,不再等大模型。
                Button { model.onInsertNow?() } label: {
                    HStack(spacing: 5) {
                        Text("✓").font(.system(size: 12, weight: .bold))
                        Text("立即插入").font(Vibe.Fonts.ui(12.5, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.vertical, 6).padding(.horizontal, 12)
                    .background(Capsule().fill(Vibe.Palette.accentA))
                }
                .buttonStyle(.plain)
            } else {
                Text("AI 润色中")
                    .font(Vibe.Fonts.ui(12.5, weight: .semibold))
                    .foregroundStyle(Vibe.Palette.accentB)
            }
        case .cancel:
            Text(l10n.t("hud.cancelled"))
                .font(Vibe.Fonts.ui(12.5, weight: .semibold))
                .foregroundStyle(Vibe.Palette.error)
        case .error:
            Text(l10n.t("hud.goSettings"))
                .font(Vibe.Fonts.ui(12.5, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.vertical, 6).padding(.horizontal, 12)
                .background(Capsule().fill(Vibe.Palette.error))
        case .idle:
            EmptyView()
        }
    }

    // ----- radical form -----------------------------------------------

    private var radicalBody: some View {
        VStack(spacing: 18) {
            ZStack {
                Waveform(level: model.level, phase: model.phase, bars: barCount, big: true)
                Orb(phase: model.phase, errorIcon: model.errorInfo?.icon, big: true)
            }
            .frame(width: 150, height: 150)

            if model.phase == .error {
                VStack(spacing: 2) {
                    Text(model.errorInfo?.title ?? "")
                        .font(Vibe.Fonts.ui(13.5, weight: .semibold))
                        .foregroundStyle(Vibe.Palette.text(scheme))
                    Text(model.errorInfo?.reason ?? "")
                        .font(Vibe.Fonts.ui(12))
                        .foregroundStyle(Vibe.Palette.textMuted(scheme))
                }
                .multilineTextAlignment(.center)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(model.phase == .empty ? l10n.t("hud.listening")
                         : (model.partialText.isEmpty ? "" : model.partialText))
                        .font(Vibe.Fonts.mono(16))
                        .foregroundStyle(model.phase == .empty || model.partialText.isEmpty
                                         ? Vibe.Palette.textMuted(scheme)
                                         : Vibe.Palette.text(scheme))
                        .multilineTextAlignment(.center)
                    if model.phase == .speaking { BlinkingCaret() }
                    if model.phase == .pause {
                        Text("…").foregroundStyle(Vibe.Palette.textMuted(scheme)).tracking(2)
                    }
                }
                .frame(maxWidth: 360)
            }

            if model.phase != .error {
                rightStatus.frame(minHeight: 18)
            }
        }
        .padding(.vertical, 36)
        .padding(.horizontal, 40)
        .frame(minWidth: 320, maxWidth: 460)
        .glassPanel(cornerRadius: 28,
                    glow: Vibe.Palette.accentA.opacity(0.25), glowRadius: 40)
    }
}

// MARK: - Previews (dark)

#Preview("HUD · speaking (code-switch)") {
    let m = HUDModel()
    m.phase = .speaking
    m.level = 0.85
    m.partialText = "把这个 function 改成 async"
    m.elapsed = "0:07"
    return HUDView(model: m)
        .padding(60)
        .background(Color(hex: "#0E0E12"))
        .preferredColorScheme(.dark)
}

#Preview("HUD · pause") {
    HUDView(model: HUDModel.previewPause())
        .padding(60)
        .background(Color(hex: "#0E0E12"))
        .preferredColorScheme(.dark)
}

#Preview("HUD · error") {
    HUDView(model: HUDModel.previewError())
        .padding(60)
        .background(Color(hex: "#0E0E12"))
        .preferredColorScheme(.dark)
}

#Preview("HUD · all phases (dark)") {
    let phases: [HUDModel.Phase] = [.empty, .speaking, .pause, .finalizing, .done, .cancel, .error]
    return ScrollView {
        VStack(spacing: 18) {
            ForEach(phases, id: \.self) { p in
                let m = HUDModel()
                let _ = {
                    m.phase = p
                    m.level = p == .speaking ? 0.85 : 0.08
                    m.elapsed = "0:07"
                    m.partialText = (p == .empty) ? "" : "把这个 function 改成 async"
                    if p == .error {
                        m.errorInfo = .init(icon: "🎙", title: "找不到麦克风",
                                            reason: "请插入或选择一个输入设备")
                    }
                }()
                HUDView(model: m)
            }
        }
        .padding(40)
    }
    .background(Color(hex: "#0E0E12"))
    .preferredColorScheme(.dark)
}
