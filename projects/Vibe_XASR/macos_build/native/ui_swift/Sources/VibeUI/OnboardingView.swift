// ============================================================
//  Vibe XASR — First-run onboarding wizard
//  Faithful to design-requirements §5: dark-default stepped flow with a
//  progress indicator + back/skip. Seven steps:
//    1 Try it · 2 Domains · 3 Accessibility · 4 Input Monitoring ·
//    5 Choose hotkey · 6 Cloud AI (optional) · 7 Done.
//  Each step: icon + title + 1–2 lines + primary button + live ✓/✗ status.
//
//  Platform calls (request mic / accessibility / input-monitoring, open the
//  System Settings panes, finish) are injected via `OnboardingBridge` so this
//  view stays in the framework-light VibeUI library. A 0.7s Timer refreshes the
//  live permission statuses while the window is open.
// ============================================================

import SwiftUI

// MARK: - Bridge to the host (VibeIME provides the real implementation)

/// Live permission state used by the wizard (✓ granted · neutral not-asked ·
/// ✕ denied).
public enum OnboardingPermission: Sendable {
    case granted
    case notDetermined
    case denied

    public var isGranted: Bool { self == .granted }
}

/// The host (VibeIME) implements this to wire real TCC / hotkey behaviour.
@MainActor
public protocol OnboardingBridge: AnyObject {
    // Live status reads (polled).
    func microphoneState() -> OnboardingPermission
    func accessibilityGranted() -> Bool
    func inputMonitoringGranted() -> Bool

    // Actions.
    func requestMicrophone()
    func openMicrophoneSettings()
    func requestAccessibility()
    func requestInputMonitoring()

    // ----- In-window "try it" dictation (page 1) -----
    // The host owns a HUDModel it drives ONLY for the try session (phase /
    // level / partialText). The view binds to it to render live text + a
    // waveform. `startTrySession()` requests the mic if needed (the contextual
    // macOS prompt fires here on first ever press), starts capture and routes
    // engine output INTO `tryModel` instead of pasting. `stopTrySession()`
    // finalizes + stops the mic; the recognized text remains in `tryModel`.
    // CONTRACT: the try path never calls Paste (no Accessibility) and never
    // uses the global Hotkey (no Input Monitoring) — only the microphone.
    var tryModel: HUDModel { get }
    func startTrySession()
    func stopTrySession()

    // Hotkey persistence (also restarts the global listener host-side).
    var hotkeyKeyCode: Int { get }
    var hotkeyModifierOnly: Bool { get }
    func setHotkey(keyCode: Int, modifierOnly: Bool)

    // Default hotword domains.
    var hotwordDomainIDs: [String] { get set }
    func applyHotwordDomains(_ ids: [String])
    var cloudConfig: CloudConfigDTO { get set }

    // Lifecycle. `onboardingWindowDidAppear/Disappear` let the host suspend the
    // global hotkey while the wizard is open (the try uses an on-screen button).
    func onboardingWindowDidAppear()
    func onboardingWindowDidDisappear()
    func finishOnboarding()
}

public extension OnboardingBridge {
    // Default no-ops so older hosts still compile; the real host overrides them.
    func onboardingWindowDidAppear() {}
    func onboardingWindowDidDisappear() {}
    var hotwordDomainIDs: [String] { get { [] } set {} }
    func applyHotwordDomains(_ ids: [String]) {}
    var cloudConfig: CloudConfigDTO { get { .init() } set {} }
}

// MARK: - Step model

private enum OnboStep: Int, CaseIterable {
    // try-first flow: taste the product (mic only) BEFORE the permission asks.
    case tryIt, domains, accessibility, input, hotkey, cloud, done

    var title: String {
        switch self {
        case .tryIt:         return "先试一句"
        case .domains:       return "选择你的常用场景"
        case .accessibility: return "允许写入任意应用"
        case .input:         return "允许检测触发键"
        case .hotkey:        return "设置语音输入热键"
        case .cloud:         return "可选：接入云端 AI"
        case .done:          return "准备开始"
        }
    }
    var icon: String {
        switch self {
        case .tryIt:         return "🎙"
        case .domains:       return "📚"
        case .accessibility: return "♿️"
        case .input:         return "⌨️"
        case .hotkey:        return "⚡️"
        case .cloud:         return "☁️"
        case .done:          return "🎉"
        }
    }
}

// MARK: - Onboarding window content

public struct OnboardingView: View {
    @Environment(\.colorScheme) private var scheme
    @ObservedObject private var l10n = L10n.shared

    private let bridge: OnboardingBridge
    /// Live try-session output (phase / level / partialText) the host drives.
    @ObservedObject private var tryModel: HUDModel

    @State private var step: OnboStep = .tryIt
    // Whether the on-screen "按住说话" button is currently held.
    @State private var holding = false
    // Live permission snapshots, refreshed by the timer.
    @State private var micState: OnboardingPermission = .notDetermined
    @State private var a11yGranted = false
    @State private var inputGranted = false
    // Hotkey selection (seeded from the store via the bridge).
    @State private var hotkeyCode: Int = 54
    @State private var hotkeyIsModifier = true
    @State private var selectedDomainIDs: Set<String>
    @State private var cloudConfig: CloudConfigDTO
    @State private var cloudError = ""

    /// 0.7 s poll while the window is open.
    private let pollTimer = Timer.publish(every: 0.7, on: .main, in: .common).autoconnect()

    public init(bridge: OnboardingBridge) {
        self.bridge = bridge
        self.tryModel = bridge.tryModel
        _hotkeyCode = State(initialValue: bridge.hotkeyKeyCode)
        _hotkeyIsModifier = State(initialValue: bridge.hotkeyModifierOnly)
        _selectedDomainIDs = State(initialValue: Set(bridge.hotwordDomainIDs))
        _cloudConfig = State(initialValue: Self.seedCloudConfig(from: bridge.cloudConfig))
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Vibe.Palette.hairline(scheme))
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 40)
            footer
        }
        .frame(width: 560, height: 480)
        .background(Vibe.Palette.bg(scheme))
        .environment(\.colorScheme, .dark)               // dark default per §5
        .onAppear {
            refresh()
            bridge.onboardingWindowDidAppear()
        }
        .onDisappear {
            // If the user closes the window mid-hold, make sure capture stops.
            if holding { bridge.stopTrySession(); holding = false }
            bridge.onboardingWindowDidDisappear()
        }
        .onReceive(pollTimer) { _ in refresh() }
    }

    // ----- header: progress dots --------------------------------------

    private var header: some View {
        HStack(spacing: 8) {
            ForEach(OnboStep.allCases, id: \.rawValue) { s in
                Capsule()
                    .fill(s.rawValue <= step.rawValue
                          ? AnyShapeStyle(Vibe.accentGradient)
                          : AnyShapeStyle(Vibe.Palette.surface2(scheme)))
                    .frame(width: s == step ? 26 : 12, height: 5)
                    .animation(Vibe.Motion.spring, value: step)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .background(Vibe.Palette.surface(scheme))
    }

    // ----- center content (switches per step) -------------------------

    @ViewBuilder
    private var content: some View {
        switch step {
        case .tryIt:         tryStep
        case .domains:       domainsStep
        case .accessibility: accessibilityStep
        case .input:         inputStep
        case .hotkey:        hotkeyStep
        case .cloud:         cloudStep
        case .done:          doneStep
        }
    }

    private func stepScaffold<Status: View, Action: View>(
        _ s: OnboStep,
        lines: [String],
        @ViewBuilder status: () -> Status,
        @ViewBuilder action: () -> Action
    ) -> some View {
        VStack(spacing: 16) {
            Spacer(minLength: 0)
            Text(s.icon).font(.system(size: 56))
            Text(s.title)
                .font(Vibe.Fonts.ui(22, weight: .bold))
                .foregroundStyle(Vibe.Palette.text(scheme))
            VStack(spacing: 5) {
                ForEach(lines.indices, id: \.self) { i in
                    Text(lines[i])
                        .font(Vibe.Fonts.ui(13.5))
                        .foregroundStyle(Vibe.Palette.textMuted(scheme))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            status()
            action()
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
    }

    // 1 — Try it (NEW first page): hold the on-screen button, speak, watch the
    //     text stream into an in-window box. Needs ONLY the microphone; the
    //     contextual macOS mic prompt fires on the first ever press.
    private var tryStep: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 0)

            Text(l10n.t("onbo.welcome.title"))
                .font(Vibe.Fonts.ui(21, weight: .bold))
                .foregroundStyle(Vibe.Palette.text(scheme))
                .multilineTextAlignment(.center)
            Text(l10n.t("onbo.welcome.local"))
                .font(Vibe.Fonts.ui(13))
                .foregroundStyle(Vibe.Palette.textMuted(scheme))

            // Live in-window transcript box + a small waveform/level overlay.
            tryTranscriptBox

            // The big inviting press-and-hold button.
            holdToTalkButton

            // Subtle mic status: only surfaces if the user denied the mic.
            tryMicHint

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
    }

    private var domainsStep: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 0)
            Text("先选一个最常用的场景，Vibe XASR 会优先按你的使用领域优化识别结果。")
                .font(Vibe.Fonts.ui(13))
                .foregroundStyle(Vibe.Palette.textMuted(scheme))
                .multilineTextAlignment(.center)
            ScrollView {
                let columns = [GridItem(.flexible(minimum: 0, maximum: .infinity), spacing: 10),
                               GridItem(.flexible(minimum: 0, maximum: .infinity), spacing: 10)]
                LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
                    ForEach(HotwordDomainCatalog.all) { domain in
                        DomainRow(
                            name: domain.name,
                            summary: domain.summary,
                            selected: selectedDomainIDs.contains(domain.id)
                        ) {
                            toggleDomain(domain.id)
                        }
                    }
                }
                .padding(.horizontal, 2)
                .padding(.vertical, 2)
            }
            .frame(maxWidth: 472, maxHeight: 220)
            OnboPrimaryButton(title: "应用选择并继续") {
                bridge.applyHotwordDomains(Array(selectedDomainIDs))
                advance()
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .onAppear {
            if selectedDomainIDs.isEmpty, let first = HotwordDomainCatalog.all.first {
                selectedDomainIDs = [first.id]
            }
        }
    }

    /// Read-only streaming transcript: shows the placeholder, the live partial
    /// while holding, or the finalized text after release. A tiny waveform rides
    /// in the corner while listening.
    private var tryTranscriptBox: some View {
        let listening = tryModel.phase.isListening
        let hasText = !tryModel.partialText.isEmpty
        return ZStack(alignment: .topTrailing) {
            RoundedRectangle(cornerRadius: Vibe.Radius.card, style: .continuous)
                .fill(Vibe.Palette.surface(scheme))
                .overlay(
                    RoundedRectangle(cornerRadius: Vibe.Radius.card, style: .continuous)
                        .strokeBorder(listening ? Vibe.Palette.accentA.opacity(0.55)
                                                : Vibe.Palette.hairline(scheme),
                                      lineWidth: listening ? 1.5 : 1)
                )
                .shadow(color: listening ? Vibe.Palette.accentA.opacity(0.18) : .clear,
                        radius: listening ? 8 : 0)

            ScrollView {
                Text(hasText ? tryModel.partialText
                             : (listening ? "正在聆听…" : "松开按钮后，识别到的文字会显示在这里"))
                    .font(Vibe.Fonts.mono(15))
                    .foregroundStyle(hasText ? Vibe.Palette.text(scheme)
                                             : Vibe.Palette.textMuted(scheme))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .multilineTextAlignment(.leading)
                    .textSelection(.enabled)
                    .padding(14)
            }

            // Small live waveform in the top-right while capturing.
            if listening {
                Waveform(level: tryModel.level, phase: tryModel.phase, bars: 16)
                    .frame(width: 44, height: 24)
                    .padding(10)
                    .transition(.opacity)
            }
        }
        .frame(height: 132)
        .frame(maxWidth: 460)
        .animation(Vibe.Motion.easeOut, value: listening)
    }

    /// Press-and-hold button. `.onLongPressGesture` is unreliable for "hold",
    /// so a 0-distance DragGesture is used: onChanged starts the try the first
    /// frame the finger is down; onEnded releases + finalizes.
    private var holdToTalkButton: some View {
        let label = holding ? "正在聆听，松开结束" : "按住说话"
        return Text(label)
            .font(Vibe.Fonts.ui(16, weight: .semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: 280)
            .padding(.vertical, 18)
            .background(
                RoundedRectangle(cornerRadius: Vibe.Radius.pill, style: .continuous)
                    .fill(Vibe.accentGradient)
            )
            .scaleEffect(holding ? 0.97 : 1.0)
            .shadow(color: Vibe.Palette.accentA.opacity(holding ? 0.55 : 0.35),
                    radius: holding ? 18 : 10, y: holding ? 8 : 5)
            .overlay(
                RoundedRectangle(cornerRadius: Vibe.Radius.pill, style: .continuous)
                    .strokeBorder(Color.white.opacity(holding ? 0.35 : 0.0), lineWidth: 1.5)
            )
            .animation(Vibe.Motion.spring, value: holding)
            .contentShape(RoundedRectangle(cornerRadius: Vibe.Radius.pill, style: .continuous))
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        if !holding {            // first frame finger is down → start
                            holding = true
                            bridge.startTrySession()
                        }
                    }
                    .onEnded { _ in
                        if holding {             // release → finalize, keep text
                            holding = false
                            bridge.stopTrySession()
                        }
                    }
            )
            .accessibilityLabel("按住说话")
    }

    /// Only shown when the mic is explicitly denied; offers a deep-link.
    @ViewBuilder
    private var tryMicHint: some View {
        switch micState {
        case .denied:
            Button { bridge.openMicrophoneSettings() } label: {
                Text("麦克风未开启，去授权 ›")
                    .font(Vibe.Fonts.ui(12.5, weight: .semibold))
                    .foregroundStyle(Vibe.Palette.error)
            }
            .buttonStyle(.plain)
        default:
            // Reserve the row height so the layout doesn't jump when it appears.
            Text(" ").font(Vibe.Fonts.ui(12.5)).foregroundStyle(.clear)
        }
    }

    // 2 — Accessibility (frame: "to dictate into ANY app you need this")
    private var accessibilityStep: some View {
        stepScaffold(.accessibility,
            lines: ["刚才的试说内容只会留在这个窗口里。",
                    "想把语音结果写进任意 App，需要开启「辅助功能」权限。"],
            status: { PermStatus(granted: a11yGranted) },
            action: {
                if a11yGranted {
                    OnboPrimaryButton(title: "下一步") { advance() }
                } else {
                    OnboPrimaryButton(title: "去开启辅助功能") {
                        bridge.requestAccessibility()
                    }
                }
            })
    }

    // 3 — Input Monitoring
    private var inputStep: some View {
        stepScaffold(.input,
            lines: ["Vibe XASR 需要「输入监控」权限来识别你按下的热键。",
                    "开启后，就可以在任意位置按住热键开始说话。"],
            status: { PermStatus(granted: inputGranted) },
            action: {
                if inputGranted {
                    OnboPrimaryButton(title: "下一步") { advance() }
                } else {
                    OnboPrimaryButton(title: "去开启输入监控") {
                        bridge.requestInputMonitoring()
                    }
                }
            })
    }

    // 4 — Choose hotkey
    private var hotkeyStep: some View {
        stepScaffold(.hotkey,
            lines: ["这里设置你的语音输入触发键。",
                    "默认是右 ⌘，第一次使用时就可以直接改成自己顺手的按键。"],
            status: {
                HStack(spacing: 10) {
                    Text("语音输入")
                        .font(Vibe.Fonts.ui(12.5))
                        .foregroundStyle(Vibe.Palette.textMuted(scheme))
                        .frame(width: 64, alignment: .leading)
                    HotkeyRecorder(keyCode: $hotkeyCode,
                                   isModifier: $hotkeyIsModifier) { code, mod in
                        bridge.setHotkey(keyCode: code, modifierOnly: mod)
                    }
                }
            },
            action: {
                VStack(spacing: 8) {
                    Text("试一下：按住「\(VibeKeycodes.name(hotkeyCode))」说一句话。")
                        .font(Vibe.Fonts.ui(12))
                        .foregroundStyle(Vibe.Palette.accentB)
                    Text("后续你也可以在设置里随时修改这个热键。")
                        .font(Vibe.Fonts.ui(11.5))
                        .foregroundStyle(Vibe.Palette.textMuted(scheme))
                        .multilineTextAlignment(.center)
                    OnboPrimaryButton(title: "下一步") {
                        bridge.setHotkey(keyCode: hotkeyCode, modifierOnly: hotkeyIsModifier)
                        advance()
                    }
                }
            })
    }

    // 5 — Optional cloud AI setup
    private var cloudStep: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 0)
            Text("如果你希望语音结果进一步整理得更自然、更完整，可以在这里先接入云端 AI。")
                .font(Vibe.Fonts.ui(13))
                .foregroundStyle(Vibe.Palette.textMuted(scheme))
                .multilineTextAlignment(.center)
            Text("这一步可以跳过。即使现在不配置，后面也能随时在设置里补上。")
                .font(Vibe.Fonts.ui(12))
                .foregroundStyle(Vibe.Palette.textMuted(scheme))
                .multilineTextAlignment(.center)

            VStack(alignment: .leading, spacing: 12) {
                OnboardingCloudField("服务商") {
                    Picker("", selection: Binding(
                        get: { cloudConfig.provider },
                        set: { applyProvider($0) })) {
                        ForEach(CloudProvidersUI.all, id: \.key) { provider in
                            Text(provider.label).tag(provider.key)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                }
                OnboardingCloudField("Base URL") {
                    TextField("https://your-proxy.example.com/v1",
                              text: Binding(
                                get: { cloudConfig.baseURL },
                                set: { cloudConfig.baseURL = $0; cloudError = "" }))
                        .textFieldStyle(.roundedBorder)
                        .font(Vibe.Fonts.mono(12))
                }
                OnboardingCloudField("模型") {
                    TextField("gpt-4o-mini",
                              text: Binding(
                                get: { cloudConfig.model },
                                set: { cloudConfig.model = $0; cloudError = "" }))
                        .textFieldStyle(.roundedBorder)
                        .font(Vibe.Fonts.mono(12))
                }
                OnboardingCloudField("API Key") {
                    SecureField("API Key",
                                text: Binding(
                                    get: { cloudConfig.apiKey },
                                    set: { cloudConfig.apiKey = $0; cloudError = "" }))
                        .textFieldStyle(.roundedBorder)
                        .font(Vibe.Fonts.mono(12))
                }
            }
            .frame(maxWidth: 460)

            if !cloudError.isEmpty {
                Text(cloudError)
                    .font(Vibe.Fonts.ui(11.5))
                    .foregroundStyle(Vibe.Palette.error)
                    .frame(maxWidth: 460, alignment: .leading)
            }

            HStack(spacing: 10) {
                OnboPrimaryButton(title: "跳过") {
                    skipCloud()
                }
                OnboPrimaryButton(title: "启用并继续") {
                    enableCloudAndContinue()
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
    }

    private var doneStep: some View {
        stepScaffold(.done,
            lines: ["现在开始，你可以在任意输入框按住「\(VibeKeycodes.name(hotkeyCode))」直接说话。",
                    "词典、云端 AI 和更多输入设置都可以稍后慢慢完善。"],
            status: { EmptyView() },
            action: {
                OnboPrimaryButton(title: "完成") {
                    bridge.finishOnboarding()
                }
            })
    }

    private func toggleDomain(_ id: String) {
        if selectedDomainIDs.contains(id) {
            selectedDomainIDs.remove(id)
        } else {
            selectedDomainIDs.insert(id)
        }
    }

    private func applyProvider(_ key: String) {
        cloudError = ""
        cloudConfig.provider = key
        let provider = CloudProvidersUI.find(key)
        cloudConfig.baseURL = provider.baseURL
        cloudConfig.model = provider.defaultModel
    }

    private func skipCloud() {
        cloudError = ""
        cloudConfig.enabled = false
        bridge.cloudConfig = cloudConfig
        advance()
    }

    private func enableCloudAndContinue() {
        let baseURL = cloudConfig.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = cloudConfig.model.trimmingCharacters(in: .whitespacesAndNewlines)
        let apiKey = cloudConfig.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !baseURL.isEmpty, !model.isEmpty, !apiKey.isEmpty else {
            cloudError = "要启用云端 AI，请先填写完整的 Base URL、模型和 API Key。"
            return
        }
        cloudError = ""
        cloudConfig.baseURL = baseURL
        cloudConfig.model = model
        cloudConfig.apiKey = apiKey
        cloudConfig.enabled = true
        bridge.cloudConfig = cloudConfig
        advance()
    }

    // ----- footer: back / skip ----------------------------------------

    private var footer: some View {
        HStack {
            if step != .tryIt {                      // first page has no "back"
                Button(action: back) {
                    Text("‹ 上一步")
                        .font(Vibe.Fonts.ui(12.5))
                        .foregroundStyle(Vibe.Palette.textMuted(scheme))
                }
                .buttonStyle(.plain)
            }
            Spacer()
            // The try page can always advance (user may skip trying); other
            // pre-done steps keep a quiet "跳过 整个向导" affordance.
            if step == .tryIt {
                Button(action: { stopHoldIfNeeded(); advance() }) {
                    Text("下一步 ›")
                        .font(Vibe.Fonts.ui(13, weight: .semibold))
                        .foregroundStyle(Vibe.Palette.accentB)
                }
                .buttonStyle(.plain)
            } else if step != .done {
                Button(action: { bridge.finishOnboarding() }) {
                    Text("先跳过")
                        .font(Vibe.Fonts.ui(12.5))
                        .foregroundStyle(Vibe.Palette.textMuted(scheme))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background(Vibe.Palette.surface(scheme))
        .overlay(Rectangle().fill(Vibe.Palette.hairline(scheme)).frame(height: 1),
                 alignment: .top)
    }

    /// Safety: if the user taps "下一步" while still pressing the hold button,
    /// finalize the in-flight try first.
    private func stopHoldIfNeeded() {
        if holding { bridge.stopTrySession(); holding = false }
    }

    // ----- navigation + polling ---------------------------------------

    private func advance() {
        let next = min(step.rawValue + 1, OnboStep.allCases.count - 1)
        withAnimation(Vibe.Motion.easeOut) {
            step = OnboStep(rawValue: next) ?? step
        }
    }

    private func back() {
        let prev = max(step.rawValue - 1, 0)
        withAnimation(Vibe.Motion.easeOut) {
            step = OnboStep(rawValue: prev) ?? step
        }
    }

    /// Pull fresh permission snapshots; auto-advance off a11y/input when a
    /// just-granted permission unblocks the step (spec allows auto-advance).
    /// The mic is obtained contextually on the try page, so it has no gated
    /// step and never auto-advances — `micState` only drives the subtle hint.
    private func refresh() {
        let prevA11y = a11yGranted, prevInput = inputGranted
        micState = bridge.microphoneState()
        a11yGranted = bridge.accessibilityGranted()
        inputGranted = bridge.inputMonitoringGranted()

        switch step {
        case .accessibility where !prevA11y && a11yGranted:
            advance()
        case .input where !prevInput && inputGranted:
            advance()
        default:
            break
        }
    }
}

private extension OnboardingView {
    static func seedCloudConfig(from current: CloudConfigDTO) -> CloudConfigDTO {
        var cfg = current
        if cfg.provider.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || cfg.provider == "openai_compatible" {
            cfg.provider = "openai"
        }
        let provider = CloudProvidersUI.find(cfg.provider)
        if cfg.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || cfg.baseURL == "https://api.openai.com/v1" {
            cfg.baseURL = provider.baseURL
        }
        if cfg.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || cfg.model == "gpt-4o-mini" {
            cfg.model = provider.defaultModel
        }
        cfg.enabled = false
        return cfg
    }
}

// MARK: - Small step pieces

/// ✓ / ✕ / neutral status pill for a tri-state permission.
private struct PermStatus: View {
    var state: OnboardingPermission

    init(state: OnboardingPermission) { self.state = state }
    init(granted: Bool) { self.state = granted ? .granted : .notDetermined }

    var body: some View {
        switch state {
        case .granted:
            pill(text: "✓ 已授权", color: Vibe.Palette.success)
        case .denied:
            pill(text: "✕ 已拒绝 · 请在系统设置开启", color: Vibe.Palette.error)
        case .notDetermined:
            pill(text: "○ 等待授权", color: Vibe.Palette.warn)
        }
    }

    private func pill(text: String, color: Color) -> some View {
        Text(text)
            .font(Vibe.Fonts.ui(12.5, weight: .semibold))
            .foregroundStyle(color)
            .padding(.vertical, 6).padding(.horizontal, 13)
            .background(Capsule().fill(color.opacity(0.16)))
    }
}

/// Solid accent primary button (danger variant tints it red), used by each step.
private struct OnboPrimaryButton: View {
    var title: String
    var danger: Bool = false
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Vibe.Fonts.ui(14, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.vertical, 10).padding(.horizontal, 26)
                .background(
                    RoundedRectangle(cornerRadius: Vibe.Radius.control, style: .continuous)
                        .fill(danger
                              ? AnyShapeStyle(Vibe.Palette.error)
                              : AnyShapeStyle(Vibe.accentGradient))
                )
                .shadow(color: (danger ? Vibe.Palette.error : Vibe.Palette.accentA).opacity(0.35),
                        radius: 10, y: 5)
        }
        .buttonStyle(.plain)
        .padding(.top, 4)
    }
}

private struct OnboardingCloudField<Content: View>: View {
    @Environment(\.colorScheme) private var scheme
    var title: String
    let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(Vibe.Fonts.ui(11.5, weight: .semibold))
                .foregroundStyle(Vibe.Palette.textMuted(scheme))
            content
        }
    }
}

private struct DomainRow: View {
    @Environment(\.colorScheme) private var scheme
    var name: String
    var summary: String
    var selected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 8) {
                    Text(name)
                        .font(Vibe.Fonts.ui(13.5, weight: .semibold))
                        .foregroundStyle(selected ? .white : Vibe.Palette.text(scheme))
                        .lineLimit(2)
                    Spacer(minLength: 4)
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 18))
                        .foregroundStyle(selected ? .white : Vibe.Palette.textMuted(scheme))
                        .padding(.top, 1)
                }
                Text(summary)
                    .font(Vibe.Fonts.ui(11))
                    .foregroundStyle(selected ? .white.opacity(0.82) : Vibe.Palette.textMuted(scheme))
                    .fixedSize(horizontal: false, vertical: true)
                    .lineLimit(3)
            }
            .padding(.vertical, 11).padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 94, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(selected ? AnyShapeStyle(Vibe.accentGradient)
                                   : AnyShapeStyle(Vibe.Palette.surface2(scheme)))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(selected ? .clear : Vibe.Palette.hairline(scheme),
                                  lineWidth: selected ? 1.5 : 1)
            )
        }
        .buttonStyle(.plain)
    }
}
