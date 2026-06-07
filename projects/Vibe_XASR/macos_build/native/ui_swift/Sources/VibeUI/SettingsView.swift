// ============================================================
//  Vibe XASR — Preferences window (5 tabs)
//  General / Dictation / Model / Permissions / About.
//
//  Every visible control is wired to the real host store via `SettingsBridge`
//  and localized live via `L10n`. (Previews fall back to the protocol's inert
//  default implementations + English.) No placeholder controls remain.
// ============================================================

import SwiftUI
import Combine
import AppKit

// MARK: - Host bridge

/// The host app (VibeIME) implements this so every *live* Settings control
/// reads/writes the real SettingsStore and applies its effect immediately. When
/// nil (e.g. SwiftUI previews) the controls fall back to in-memory
/// `SettingsState`, so the existing placeholder controls keep working unchanged.
///
/// Newer members carry default implementations (see the extension below) so
/// older hosts / previews still satisfy the protocol.
@MainActor
public protocol SettingsBridge: AnyObject {
    // Dock + hotkey (original live controls).
    var showDockIcon: Bool { get set }            // setter applies activation policy live
    var hotkeyKeyCode: Int { get }
    var hotkeyModifierOnly: Bool { get }
    var hotkeyMods: Int { get }
    var hotkeyToggleMode: Bool { get set }   // false = 按住说话, true = 单击切换
    func setHotkey(keyCode: Int, modifierOnly: Bool, mods: Int)

    // ----- Engine config: VAD + latency tier (rebuilds the engine live) -----
    var vadKind: String { get set }               // "fire" | "silero"
    var latencyTier: Int { get set }              // 160/480/960/1920
    /// True while the engine is rebuilding after a VAD/tier change (UI shows 切换中…).
    var engineSwapping: Bool { get }

    // ----- Dictation behaviour -----
    var insertMethod: String { get set }          // "paste" | "type"
    var padWriteEnabled: Bool { get set }
    var historyEnabled: Bool { get set }
    var launchAtLogin: Bool { get set }
    /// Leave each dictation result on the clipboard (issue #12). Default OFF.
    var clipboardOverwrite: Bool { get set }
    /// Convert the final output to Traditional Chinese (character-level). Default OFF.
    var outputTraditional: Bool { get set }
    /// Seconds the HUD stays after each utterance (default 1 — "disappear ASAP").
    var hudStaySeconds: Double { get set }
    /// Subtle cue sound on dictation start/stop. Default ON. Setting
    /// `cueTheme` (or toggling on) previews the sound.
    var cueEnabled: Bool { get set }
    var cueTheme: String { get set }            // "tick" | "chime" | "soft" | "drop" | "marimba"
    var cueVolume: String { get set }           // "low" | "med" | "high"

    // ----- Hotwords (contextual biasing) -----
    var hotwordsEnabled: Bool { get set }       // master switch (rebuilds engine)
    var hotwordsText: String { get set }        // newline-separated list (persist only)
    var hotwordsScore: Double { get set }       // boost: 1.5 low / 2.0 mid / 3.0 high
    /// Commit the edited list + score and rebuild the engine so it takes effect.
    func applyHotwords()
    /// Homophone (pinyin) correction toward dictionary words. Applied live.
    var pinyinFuzzyEnabled: Bool { get set }
    /// Number normalization (ITN) on final text (一百二十三→123). Applied live.
    var itnEnabled: Bool { get set }
    /// Filler-word removal (嗯/呃/repeats) on final text. Applied live.
    var defillerEnabled: Bool { get set }
    /// AI polish (Beta): LLM tidy of final text (fillers + self-corrections). Applied live.
    var refinerEnabled: Bool { get set }
    /// 云端大模型配置(整包传递);测试连接(异步,实测往返延迟)。
    var cloudConfig: CloudConfigDTO { get set }
    func testCloud(_ cfg: CloudConfigDTO) async -> CloudTestResult
    /// 最近若干条云端润色请求(排查用,最新在前);清空。
    func cloudRecentRequests() -> [CloudReqLogEntry]
    func cloudClearRequests()

    // ----- Replacements (post-recognition corrections) -----
    var replacementsEnabled: Bool { get set }
    var replacementsText: String { get set }    // newline-separated "from => to" (persist only)
    /// Commit the edited rules (applied live; no engine rebuild).
    func applyReplacements()

    // ----- Voice snippets (trigger → multi-line expansion) -----
    var snippetsEnabled: Bool { get set }
    var snippetsJSON: String { get set }         // [{"t":trigger,"x":text}] (persist only)
    func applySnippets()

    // ----- Sub-bridge for the Model tab -----
    var modelManager: ModelManagerBridge? { get }
    /// Apply a tier selection: triggers a download if needed and swaps the engine
    /// once available. Returns immediately; progress is observed via modelManager.
    func selectTier(_ tier: Int)

    // ----- Live permission reads (so the Permissions tab is real) -----
    func micGranted() -> Bool
    func accessibilityGranted() -> Bool
    func inputMonitoringGranted() -> Bool
    func openPermissionSettings(_ which: PermissionKind)

    // ----- Microphone input device -----
    /// Available input devices; first entry is the "system default" (uid "").
    func inputDevices() -> [(uid: String, name: String)]
    var inputDeviceUID: String { get set }

    // ----- Local share API (共享 — local HTTP server for coding agents) -----
    var apiEnabled: Bool { get set }
    var apiAllowLAN: Bool { get set }
    var apiKey: String { get }
    var apiPort: Int { get }
    /// LAN IPv4 (e.g. "192.168.1.20") when resolvable + LAN allowed, else nil.
    var apiLANHost: String? { get }
    @discardableResult func regenerateAPIKey() -> String

    // ----- Auto-update (Sparkle, implemented in the app target) -----
    /// User-initiated update check. The host drives Sparkle's updater UI
    /// (checks the appcast, downloads + verifies + installs if a newer build exists).
    func checkForUpdates()
}

/// Which permission a "open System Settings" button targets.
public enum PermissionKind: Sendable { case microphone, accessibility, inputMonitoring }

// MARK: - Model download source (line / 线路)

/// Which mirror a tier download pulls from. ModelScope is the default (faster in
/// CN); HuggingFace is the alternative. The concrete host downloader persists the
/// choice in UserDefaults (NOT SettingsStore) and builds per-source URLs.
public enum ModelDownloadSource: String, CaseIterable, Sendable {
    case official     // CDN 加速线路(默认);对用户只显示「CDN加速链接」,不暴露域名
    case modelScope
    case huggingFace

    /// Short label shown in the segmented picker.
    public var label: String {
        switch self {
        case .official:    return "CDN加速链接"
        case .modelScope:  return "ModelScope"
        case .huggingFace: return "HuggingFace"
        }
    }

    /// Public model page for this source (opened when the value link is tapped).
    public var repoURL: URL {
        switch self {
        case .official:    return URL(string: "https://github.com/Gilgamesh-J/X-ASR")!
        case .modelScope:  return URL(string: "https://www.modelscope.ai/models/Gilgamesh-J/X-ASR-zh-en")!
        case .huggingFace: return URL(string: "https://huggingface.co/GilgameshWind/X-ASR-zh-en")!
        }
    }

    /// host/owner/name shown as the tappable monospace value under the picker.
    public var repoDisplay: String {
        switch self {
        case .official:    return ""    // 官方加速:不显示域名/IP
        case .modelScope:  return "modelscope.ai/Gilgamesh-J/X-ASR-zh-en"
        case .huggingFace: return "huggingface.co/GilgameshWind/X-ASR-zh-en"
        }
    }
}

/// UI-side seam for the download-line picker. The host's ModelDownloader (an
/// ObservableObject living in the app target) conforms; the Model tab downcasts
/// its `manager` to this to read/write the line. Defined here (not in Bridges.swift)
/// so VibeUI owns the contract the picker depends on.
@MainActor
public protocol ModelDownloadSourcing: AnyObject {
    var source: ModelDownloadSource { get set }
}

// Default implementations so previews / older hosts compile. These are inert.
public extension SettingsBridge {
    var vadKind: String { get { "fire" } set {} }
    var latencyTier: Int { get { 960 } set {} }
    var engineSwapping: Bool { false }
    var insertMethod: String { get { "paste" } set {} }
    var padWriteEnabled: Bool { get { false } set {} }
    var historyEnabled: Bool { get { true } set {} }
    var launchAtLogin: Bool { get { false } set {} }
    var clipboardOverwrite: Bool { get { false } set {} }
    var outputTraditional: Bool { get { false } set {} }
    var hudStaySeconds: Double { get { 0.5 } set {} }
    var hotkeyMods: Int { 0 }
    var hotkeyToggleMode: Bool { get { false } set {} }
    var cueEnabled: Bool { get { true } set {} }
    var cueTheme: String { get { "chime" } set {} }
    var cueVolume: String { get { "low" } set {} }
    var hotwordsEnabled: Bool { get { false } set {} }
    var hotwordsText: String { get { "" } set {} }
    var hotwordsScore: Double { get { 5.0 } set {} }
    func applyHotwords() {}
    var pinyinFuzzyEnabled: Bool { get { true } set {} }
    var itnEnabled: Bool { get { true } set {} }
    var defillerEnabled: Bool { get { true } set {} }
    var refinerEnabled: Bool { get { false } set {} }
    var cloudConfig: CloudConfigDTO { get { .init() } set {} }
    func testCloud(_ cfg: CloudConfigDTO) async -> CloudTestResult { .init(msg: "预览不可用") }
    func cloudRecentRequests() -> [CloudReqLogEntry] { [] }
    func cloudClearRequests() {}
    var replacementsEnabled: Bool { get { false } set {} }
    var replacementsText: String { get { "" } set {} }
    func applyReplacements() {}
    var snippetsEnabled: Bool { get { true } set {} }
    var snippetsJSON: String { get { "[]" } set {} }
    func applySnippets() {}
    var modelManager: ModelManagerBridge? { nil }
    func selectTier(_ tier: Int) {}
    func micGranted() -> Bool { true }
    func accessibilityGranted() -> Bool { false }
    func inputMonitoringGranted() -> Bool { false }
    func openPermissionSettings(_ which: PermissionKind) {}
    func inputDevices() -> [(uid: String, name: String)] { [] }
    var inputDeviceUID: String { get { "" } set {} }
    var apiEnabled: Bool { get { false } set {} }
    var apiAllowLAN: Bool { get { false } set {} }
    var apiKey: String { "vibe_demo_key" }
    var apiPort: Int { 8765 }
    var apiLANHost: String? { nil }
    @discardableResult func regenerateAPIKey() -> String { "vibe_demo_key" }
}

// MARK: - Model-manager observation relay (issue #13 fix)

/// SwiftUI does NOT observe `@Published` changes through an existential like
/// `any ModelManagerBridge & ObservableObject` — only a CONCRETE `@ObservedObject`
/// / `@StateObject` triggers re-renders. So download progress published by the
/// host's `ModelDownloader` never reached the Model tab and the bar sat frozen.
///
/// This concrete relay subscribes to the erased manager's `objectWillChange` and
/// re-publishes it, so a `@StateObject ModelManagerRelay` in the Model tab DOES
/// re-render live as progress advances. It forwards the bridge calls through.
@MainActor
public final class ModelManagerRelay: ObservableObject {
    /// The erased concrete manager (host's ModelDownloader). May be nil in previews.
    public let manager: (any ModelManagerBridge & ObservableObject)?
    private var cancellable: AnyCancellable?

    public init(_ manager: (any ModelManagerBridge & ObservableObject)?) {
        self.manager = manager
        // Bridge the erased object's change publisher to ours. `eraseObjectWillChange`
        // hides the associated-type so we can subscribe through the existential.
        if let m = manager {
            cancellable = m.eraseObjectWillChange()
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in self?.objectWillChange.send() }
        }
    }

    // Convenience pass-throughs the Model tab reads each render.
    func isTierDownloaded(_ tier: LatencyTier) -> Bool { manager?.isTierDownloaded(tier) ?? tier.isBundled }
    func downloadProgress(_ tier: LatencyTier) -> Double? { manager?.downloadProgress(tier) }
    func didTierFail(_ tier: LatencyTier) -> Bool { manager?.didTierFail(tier) ?? false }
    func startDownload(_ tier: LatencyTier) { manager?.startDownload(tier) }
    func cancelDownload(_ tier: LatencyTier) { manager?.cancelDownload(tier) }
    @discardableResult func deleteTier(_ tier: LatencyTier) -> Bool { manager?.deleteTier(tier) ?? false }

    // AI 润色(本地 Beta)GGUF 下载 —— 透传给 LLMTab。
    func refinerAvailable() -> Bool { manager?.refinerAvailable() ?? false }
    func refinerDownloadProgress() -> Double? { manager?.refinerDownloadProgress() ?? nil }
    func refinerDownloadFailed() -> Bool { manager?.refinerDownloadFailed() ?? false }
    func startRefinerDownload() { manager?.startRefinerDownload() }
    @discardableResult func deleteRefiner() -> Bool { manager?.deleteRefiner() ?? false }
    /// 当前下载线路(refiner 与 ASR 共用同一 source);用于展示「下载来源」。
    var refinerSource: ModelDownloadSource { (manager as? ModelDownloadSourcing)?.source ?? .official }
}

private extension ObservableObject {
    /// Type-erase `objectWillChange` so it can be subscribed through an existential.
    func eraseObjectWillChange() -> AnyPublisher<Void, Never> {
        objectWillChange.map { _ in () }.eraseToAnyPublisher()
    }
}

// MARK: - Backing state (transient UI only)

/// Minimal transient state. All *persisted* settings now live behind the bridge;
/// this only holds the hotkey display mirror used while a bridge is present, and
/// the in-memory fallbacks used by previews (no bridge).
@MainActor
public final class SettingsState: ObservableObject {
    // Hotkey mirror (display name + live values).
    @Published public var combo = "Right ⌘"
    @Published public var hotkeyKeyCode = 54
    @Published public var hotkeyModifierOnly = true
    @Published public var hotkeyMods = 0   // HotkeyMods.rawValue;0 = 纯修饰/单键,非 0 = 组合(⌥1)
    @Published public var hotkeyToggle = false   // false = 按住说话, true = 单击切换

    // Preview-only fallbacks (used when bridge == nil).
    @Published public var showDockIcon = true
    @Published public var vad = "fire"
    @Published public var latency = 960
    @Published public var insert = "paste"
    @Published public var padWrite = false
    @Published public var history = true
    @Published public var launchAtLogin = false
    @Published public var clipOverwrite = false
    @Published public var toTraditional = false   // 输出转繁体
    @Published public var hudStay: Double = 0.5    // 说完后悬浮条停留秒数
    @Published public var cueEnabled = true
    @Published public var cueTheme = "chime"
    @Published public var cueVolume = "low"
    @Published public var inputDeviceUID = ""
    @Published public var hotwordsEnabled = false
    @Published public var hotwordsText = ""
    @Published public var hotwordsScore: Double = 5.0
    @Published public var pinyinFuzzy = true
    @Published public var itn = true
    @Published public var defiller = true
    @Published public var refiner = false
    @Published public var cloud = CloudConfigDTO()
    @Published public var replacementsEnabled = false
    @Published public var replacementsText = ""
    @Published public var snippetsEnabled = true
    @Published public var snippetsJSON = "[]"
    @Published public var apiEnabled = false
    @Published public var apiAllowLAN = false
    @Published public var apiKey = ""

    /// Host bridge; when set, controls read/write through it.
    public weak var bridge: SettingsBridge?

    public init() {}

    /// Seed the live values from the bridge (called by SettingsView at init).
    public func bind(to bridge: SettingsBridge) {
        self.bridge = bridge
        self.showDockIcon = bridge.showDockIcon
        self.hotkeyKeyCode = bridge.hotkeyKeyCode
        self.hotkeyModifierOnly = bridge.hotkeyModifierOnly
        self.hotkeyMods = bridge.hotkeyMods
        self.hotkeyToggle = bridge.hotkeyToggleMode
        self.combo = VibeKeycodes.displayName(keyCode: bridge.hotkeyKeyCode,
                                              modifierOnly: bridge.hotkeyModifierOnly,
                                              mods: HotkeyMods(rawValue: bridge.hotkeyMods))
        self.vad = bridge.vadKind
        self.latency = bridge.latencyTier
        self.insert = bridge.insertMethod
        self.padWrite = bridge.padWriteEnabled
        self.history = bridge.historyEnabled
        self.launchAtLogin = bridge.launchAtLogin
        self.clipOverwrite = bridge.clipboardOverwrite
        self.toTraditional = bridge.outputTraditional
        self.hudStay = bridge.hudStaySeconds
        self.cueEnabled = bridge.cueEnabled
        self.cueTheme = bridge.cueTheme
        self.cueVolume = bridge.cueVolume
        self.inputDeviceUID = bridge.inputDeviceUID
        self.hotwordsEnabled = bridge.hotwordsEnabled
        self.hotwordsText = bridge.hotwordsText
        self.hotwordsScore = bridge.hotwordsScore
        self.pinyinFuzzy = bridge.pinyinFuzzyEnabled
        self.itn = bridge.itnEnabled
        self.defiller = bridge.defillerEnabled
        self.refiner = bridge.refinerEnabled
        self.cloud = bridge.cloudConfig
        self.replacementsEnabled = bridge.replacementsEnabled
        self.replacementsText = bridge.replacementsText
        self.snippetsEnabled = bridge.snippetsEnabled
        self.snippetsJSON = bridge.snippetsJSON
        self.apiEnabled = bridge.apiEnabled
        self.apiAllowLAN = bridge.apiAllowLAN
        self.apiKey = bridge.apiKey
        // 不变式:AI 润色开启时听写只能是「说完插入」(兼容旧版遗留的冲突组合)。
        if polishOn { forcePasteForPolish() }
    }

    // ---- write-throughs (bridge present) or local fallback (preview) -------

    public func applyAPIEnabled(_ on: Bool) { apiEnabled = on; bridge?.apiEnabled = on }
    public func applyAPIAllowLAN(_ on: Bool) { apiAllowLAN = on; bridge?.apiAllowLAN = on }
    public func regenerateAPIKey() { apiKey = bridge?.regenerateAPIKey() ?? apiKey }

    public func applyDockIcon(_ on: Bool) {
        showDockIcon = on
        bridge?.showDockIcon = on
    }
    public func applyHotkeyToggle(_ on: Bool) {
        hotkeyToggle = on
        bridge?.hotkeyToggleMode = on
    }
    public func applyHotkey(keyCode: Int, modifierOnly: Bool, mods: HotkeyMods = []) {
        hotkeyKeyCode = keyCode
        hotkeyModifierOnly = modifierOnly
        hotkeyMods = mods.rawValue
        combo = VibeKeycodes.displayName(keyCode: keyCode, modifierOnly: modifierOnly, mods: mods)
        bridge?.setHotkey(keyCode: keyCode, modifierOnly: modifierOnly, mods: mods.rawValue)
    }
    public func applyVad(_ kind: String) {
        vad = kind
        bridge?.vadKind = kind
    }
    public func applyInsert(_ m: String) {
        insert = m
        bridge?.insertMethod = m
    }
    public func applyPadWrite(_ on: Bool) {
        padWrite = on
        bridge?.padWriteEnabled = on
    }
    public func applyHistory(_ on: Bool) {
        history = on
        bridge?.historyEnabled = on
    }
    public func applyLaunchAtLogin(_ on: Bool) {
        launchAtLogin = on
        bridge?.launchAtLogin = on
    }
    public func applyClipOverwrite(_ on: Bool) {
        clipOverwrite = on
        bridge?.clipboardOverwrite = on
    }
    public func applyToTraditional(_ on: Bool) {
        toTraditional = on
        bridge?.outputTraditional = on
    }
    public func applyHudStay(_ sec: Double) {
        hudStay = sec
        bridge?.hudStaySeconds = sec
    }
    public func applyCueEnabled(_ on: Bool) {
        cueEnabled = on
        bridge?.cueEnabled = on
    }
    public func applyCueTheme(_ t: String) {
        cueTheme = t
        bridge?.cueTheme = t
    }
    public func applyCueVolume(_ v: String) {
        cueVolume = v
        bridge?.cueVolume = v
    }
    public func applyHotwordsEnabled(_ on: Bool) {
        hotwordsEnabled = on
        bridge?.hotwordsEnabled = on   // rebuilds engine immediately
    }
    /// Commit the edited list + boost and rebuild the engine.
    public func applyHotwords(text: String, score: Double) {
        hotwordsText = text
        hotwordsScore = score
        bridge?.hotwordsText = text
        bridge?.hotwordsScore = score
        bridge?.applyHotwords()
    }
    public func applyPinyinFuzzy(_ on: Bool) {
        pinyinFuzzy = on
        bridge?.pinyinFuzzyEnabled = on
    }
    public func applyItn(_ on: Bool) {
        itn = on
        bridge?.itnEnabled = on
    }
    public func applyDefiller(_ on: Bool) {
        defiller = on
        bridge?.defillerEnabled = on
    }
    public func applyRefiner(_ on: Bool) {
        refiner = on
        bridge?.refinerEnabled = on
        if on { forcePasteForPolish() }   // 本地润色开启 → 听写只支持「说完插入」
    }
    /// 写回云端配置(整包)。UI 改任意字段后调它持久化 + 触发后端刷新。
    public func applyCloud(_ c: CloudConfigDTO) {
        cloud = c
        bridge?.cloudConfig = c
        if c.enabled { forcePasteForPolish() }   // 云端润色开启 → 听写只支持「说完插入」
    }
    /// 最新云端配置(直读 bridge → SettingsStore)。两个窗口各持一个 SettingsState 时,
    /// 提交前以此为基准合并、各自只覆盖自己负责的字段,避免跨窗口互相覆盖。preview 下为 nil。
    public var liveCloud: CloudConfigDTO? { bridge?.cloudConfig }

    /// AI 润色(云端或本地任一)是否开启。开启时听写只支持「说完插入」(paste),
    /// 逐字插入 / 持续候机 与逐句润色冲突,故置灰、需先关润色才能切换。
    public var polishOn: Bool { refiner || cloud.enabled }
    /// 润色开启时把听写模式锁回「说完插入」。
    private func forcePasteForPolish() { if insert != "paste" { applyInsert("paste") } }
    public func testCloud() async -> CloudTestResult {
        await bridge?.testCloud(cloud) ?? .init(msg: "未连接")
    }
    public func cloudRecentRequests() -> [CloudReqLogEntry] { bridge?.cloudRecentRequests() ?? [] }
    public func cloudClearRequests() { bridge?.cloudClearRequests() }
    public func inputDevices() -> [(uid: String, name: String)] { bridge?.inputDevices() ?? [] }
    public func applyInputDevice(_ uid: String) {
        inputDeviceUID = uid
        bridge?.inputDeviceUID = uid
    }
    public func applyReplacementsEnabled(_ on: Bool) {
        replacementsEnabled = on
        bridge?.replacementsEnabled = on
    }
    public func applyReplacements(text: String) {
        replacementsText = text
        bridge?.replacementsText = text
        bridge?.applyReplacements()
    }
    public func applySnippetsEnabled(_ on: Bool) {
        snippetsEnabled = on
        bridge?.snippetsEnabled = on
    }
    public func applySnippets(json: String) {
        snippetsJSON = json
        bridge?.snippetsJSON = json
        bridge?.applySnippets()
    }
    public func applyTier(_ tier: Int) {
        latency = tier
        bridge?.selectTier(tier)
    }

    // ---- permission reads (delegate to the bridge; false if no bridge) ----
    public var engineSwapping: Bool { bridge?.engineSwapping ?? false }
    public func micGranted() -> Bool { bridge?.micGranted() ?? false }
    public func a11yGranted() -> Bool { bridge?.accessibilityGranted() ?? false }
    public func inputGranted() -> Bool { bridge?.inputMonitoringGranted() ?? false }
    public func openPermission(_ kind: PermissionKind) { bridge?.openPermissionSettings(kind) }
}

// MARK: - Atomic controls

/// `.sw` toggle: accent-gradient track when on, spring-sliding white knob.
struct VibeToggle: View {
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
                          : AnyShapeStyle(scheme == .light
                                          ? Color(hex: "#D8D8DE")
                                          : Vibe.Palette.surface2(scheme)))
                    .frame(width: 42, height: 25)
                Circle()
                    .fill(Color.white)
                    .frame(width: 20, height: 20)
                    .shadow(color: .black.opacity(0.3), radius: 1.5, y: 1)
                    .padding(.horizontal, 2.5)
            }
        }
        .buttonStyle(.plain)
    }
}

/// `.seg` segmented control: muted labels, raised "on" pill.
struct VibeSegmented: View {
    @Environment(\.colorScheme) private var scheme
    @Binding var value: String
    var options: [(String, String)]   // (value, label)
    var onChange: ((String) -> Void)? = nil
    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.0) { opt in
                let isOn = value == opt.0
                Button {
                    value = opt.0
                    onChange?(opt.0)
                } label: {
                    Text(opt.1)
                        .font(Vibe.Fonts.ui(12))
                        .foregroundStyle(isOn
                                         ? Vibe.Palette.text(scheme)
                                         : Vibe.Palette.textMuted(scheme))
                        .padding(.vertical, 5).padding(.horizontal, 11)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(isOn ? Vibe.Palette.segOn(scheme) : .clear)
                                .shadow(color: isOn ? Vibe.Shadow.cardColor(scheme) : .clear,
                                        radius: isOn ? Vibe.Shadow.cardRadius : 0,
                                        y: isOn ? Vibe.Shadow.cardY : 0)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: Vibe.Radius.control, style: .continuous)
                .fill(Vibe.Palette.surface2(scheme))
        )
    }
}

/// `.sel` dropdown styled like the mockup (surface-2 box + chevron).
struct VibeSelect: View {
    @Environment(\.colorScheme) private var scheme
    @Binding var value: String
    var options: [(String, String)]
    var onChange: ((String) -> Void)? = nil
    var body: some View {
        Menu {
            ForEach(options, id: \.0) { opt in
                Button(opt.1) { value = opt.0; onChange?(opt.0) }
            }
        } label: {
            HStack(spacing: 8) {
                Text(options.first(where: { $0.0 == value })?.1 ?? value)
                    .font(Vibe.Fonts.ui(12.5))
                    .foregroundStyle(Vibe.Palette.text(scheme))
                Text("⌄")
                    .font(.system(size: 13))
                    .foregroundStyle(Vibe.Palette.textMuted(scheme))
                    .offset(y: -2)
            }
            .padding(.vertical, 7).padding(.leading, 12).padding(.trailing, 11)
            .background(
                RoundedRectangle(cornerRadius: Vibe.Radius.control, style: .continuous)
                    .fill(Vibe.Palette.surface2(scheme))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Vibe.Radius.control, style: .continuous)
                    .strokeBorder(Vibe.Palette.hairline(scheme), lineWidth: 1)
            )
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}

/// `.pill.ok / .pill.bad` permission status pill.
struct StatusPill: View {
    @ObservedObject private var l10n = L10n.shared
    var ok: Bool
    var body: some View {
        Text(ok ? l10n.t("perm.granted") : l10n.t("perm.denied"))
            .font(Vibe.Fonts.ui(12, weight: .semibold))
            .foregroundStyle(ok ? Vibe.Palette.success : Vibe.Palette.error)
            .padding(.vertical, 5).padding(.horizontal, 11)
            .background(
                Capsule().fill((ok ? Vibe.Palette.success : Vibe.Palette.error).opacity(0.16))
            )
    }
}

/// Solid accent button (`.m-btn`) with ghost / danger variants.
struct MButton: View {
    @Environment(\.colorScheme) private var scheme
    enum Kind { case solid, ghost, danger }
    var title: String
    var kind: Kind = .solid
    var action: () -> Void = {}
    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Vibe.Fonts.ui(12.5))
                .foregroundStyle(foreground)
                .padding(.vertical, 7).padding(.horizontal, 14)
                .background(
                    RoundedRectangle(cornerRadius: Vibe.Radius.control, style: .continuous)
                        .fill(background)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Vibe.Radius.control, style: .continuous)
                        .strokeBorder(borderColor, lineWidth: kind == .solid ? 0 : 1)
                )
        }
        .buttonStyle(.plain)
    }
    private var foreground: Color {
        switch kind {
        case .solid:  return .white
        case .ghost:  return Vibe.Palette.text(scheme)
        case .danger: return Vibe.Palette.error
        }
    }
    private var background: Color {
        switch kind {
        case .solid:  return Vibe.Palette.accentA
        case .ghost:  return Vibe.Palette.surface2(scheme)
        case .danger: return .clear
        }
    }
    private var borderColor: Color {
        switch kind {
        case .solid:  return .clear
        case .ghost:  return Vibe.Palette.hairline(scheme)
        case .danger: return Vibe.Palette.hairline(scheme)
        }
    }
}

// MARK: - Row & Group containers

/// `.row`: title + optional help on the left, a control on the right.
struct SettingsRow<Control: View>: View {
    @Environment(\.colorScheme) private var scheme
    var title: String
    var help: String? = nil
    @ViewBuilder var control: () -> Control
    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(Vibe.Fonts.ui(13.5, weight: .medium))
                    .foregroundStyle(Vibe.Palette.text(scheme))
                if let help {
                    Text(help)
                        .font(Vibe.Fonts.ui(11.5))
                        .foregroundStyle(Vibe.Palette.textMuted(scheme))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            control()
        }
        .padding(.vertical, 13).padding(.horizontal, 16)
        .background(Vibe.Palette.surface(scheme))
    }
}

/// `.grp`: an uppercase mono label over a hairline-separated card of rows.
struct SettingsGroup<Content: View>: View {
    @Environment(\.colorScheme) private var scheme
    var label: String? = nil
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let label {
                Text(label)
                    .font(Vibe.Fonts.mono(11))
                    .tracking(1.1)
                    .foregroundStyle(Vibe.Palette.textMuted(scheme))
                    .textCase(.uppercase)
                    .padding(.leading, 2).padding(.bottom, 10)
            }
            VStack(spacing: 1) {
                content()
            }
            .background(Vibe.Palette.hairline(scheme)) // 1px gaps show as hairlines
            .clipShape(RoundedRectangle(cornerRadius: Vibe.Radius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Vibe.Radius.card, style: .continuous)
                    .strokeBorder(Vibe.Palette.hairline(scheme), lineWidth: 1)
            )
        }
        .padding(.bottom, 26)
    }
}

// MARK: - Tabs

private struct GeneralTab: View {
    @ObservedObject var s: SettingsState
    @ObservedObject var l10n: L10n
    @Environment(\.colorScheme) private var scheme
    /// Switches the host's settings tab to the Permissions tab.
    var onOpenPermissions: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            SettingsGroup(label: l10n.t("grp.general")) {
                SettingsRow(title: l10n.t("gen.dock"), help: l10n.t("gen.dock.help")) {
                    VibeToggle(on: Binding(get: { s.showDockIcon },
                                           set: { s.applyDockIcon($0) }))
                }
                SettingsRow(title: l10n.t("gen.launchAtLogin"), help: l10n.t("gen.launchAtLogin.help")) {
                    VibeToggle(on: Binding(get: { s.launchAtLogin },
                                           set: { s.applyLaunchAtLogin($0) }))
                }
                SettingsRow(title: l10n.t("gen.lang"), help: l10n.t("gen.lang.help")) {
                    // Real, live UI-language picker. Auto label is itself localized.
                    VibeSelect(
                        value: Binding(get: { l10n.lang.rawValue },
                                       set: { l10n.lang = Lang(rawValue: $0) ?? .auto }),
                        options: Lang.allCases.map {
                            ($0.rawValue, $0 == .auto ? l10n.autoLabel() : $0.display)
                        })
                }
            }

            // 触发键 + 触发方式 + 听写模式(从「听写」页移来,属高频核心交互)。
            SettingsGroup(label: l10n.t("grp.trigger")) {
                SettingsRow(title: l10n.t("dict.hotkey"), help: l10n.t("dict.hotkey.help")) {
                    GlobalHotkeyRecorder(
                        keyCode: Binding(get: { s.hotkeyKeyCode }, set: { s.hotkeyKeyCode = $0 }),
                        modifierOnly: Binding(get: { s.hotkeyModifierOnly }, set: { s.hotkeyModifierOnly = $0 }),
                        mods: Binding(get: { s.hotkeyMods }, set: { s.hotkeyMods = $0 })
                    ) { code, mod, m in
                        s.applyHotkey(keyCode: code, modifierOnly: mod, mods: m)
                    }
                }
                SettingsRow(title: l10n.t("dict.trigger"), help: l10n.t("dict.trigger.help")) {
                    Picker("", selection: Binding(get: { s.hotkeyToggle }, set: { s.applyHotkeyToggle($0) })) {
                        Text(l10n.t("dict.trigger.hold")).tag(false)
                        Text(l10n.t("dict.trigger.toggle")).tag(true)
                    }.pickerStyle(.segmented).labelsHidden().frame(width: 200)
                }
                DictationModeList(s: s, l10n: l10n)
            }

            // Self-check · helps users who hit permission problems.
            SelfCheckView(s: s, l10n: l10n, onOpenPermissions: onOpenPermissions)
        }
    }
}

/// Reusable hotkey self-check. Shows an instruction, a focusable test box that
/// dictation can type into, a permission-aware hint (warning when any of
/// mic/accessibility/input-monitoring is missing, otherwise the neutral tip),
/// and a shortcut to the Permissions tab.
private struct SelfCheckView: View {
    @ObservedObject var s: SettingsState
    @ObservedObject var l10n: L10n
    @Environment(\.colorScheme) private var scheme
    /// Switches the host's settings tab to the Permissions tab.
    var onOpenPermissions: () -> Void
    /// (General tab only) Jump to the Dictation tab to set the hotkey. nil = hide.
    var onSetHotkey: (() -> Void)? = nil

    @State private var testText = ""

    var body: some View {
        // Live permission read — drives the warning vs. neutral hint.
        let missing = (!s.micGranted() || !s.a11yGranted() || !s.inputGranted())
        SettingsGroup(label: l10n.t("selfcheck.title")) {
            VStack(alignment: .leading, spacing: 10) {
                Text(l10n.t("selfcheck.body"))
                    .font(Vibe.Fonts.ui(13))
                    .foregroundStyle(Vibe.Palette.text(scheme))
                    .fixedSize(horizontal: false, vertical: true)

                // Test box: focus it, hold the global hotkey and speak → dictation
                // types into this field, proving the hotkey path end-to-end.
                HStack(spacing: 8) {
                    TextField(l10n.t("selfcheck.placeholder"), text: $testText)
                        .textFieldStyle(.plain)
                        .font(Vibe.Fonts.ui(13))
                        .foregroundStyle(Vibe.Palette.text(scheme))
                    if !testText.isEmpty {
                        Button { testText = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(Vibe.Palette.textMuted(scheme))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 9).padding(.horizontal, 11)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Vibe.Palette.surface2(scheme))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(Vibe.Palette.hairline(scheme), lineWidth: 1)
                )

                if missing {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 12)).foregroundStyle(Vibe.Palette.error)
                        Text(l10n.t("selfcheck.warn"))
                            .font(Vibe.Fonts.ui(11.5))
                            .foregroundStyle(Vibe.Palette.error)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 12)).foregroundStyle(Vibe.Palette.warn)
                        Text(l10n.t("selfcheck.hint"))
                            .font(Vibe.Fonts.ui(11.5))
                            .foregroundStyle(Vibe.Palette.textMuted(scheme))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                HStack(spacing: 8) {
                    Spacer()
                    if let onSetHotkey {
                        MButton(title: l10n.t("selfcheck.setHotkey"), kind: .ghost) { onSetHotkey() }
                    }
                    MButton(title: l10n.t("selfcheck.openPerm"), kind: .ghost) { onOpenPermissions() }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 13).padding(.horizontal, 16)
            .background(Vibe.Palette.surface(scheme))
        }
    }
}

/// (听写模式 / Dictation mode) The three insert behaviours rendered as a
/// radio-style vertical list inside the Dictation group. Each row carries a long
/// description, so a segmented control won't fit. The whole row is the hit target;
/// selecting writes through `s.applyInsert(value)`.
private struct DictationModeList: View {
    @ObservedObject var s: SettingsState
    @ObservedObject var l10n: L10n
    @Environment(\.colorScheme) private var scheme
    /// 非 nil = 用户点了与 AI 润色冲突的模式,弹窗征询是否切换(切换=关润色)。
    @State private var pendingMode: String?

    /// (value, titleKey, descKey) for the three modes.
    private var modes: [(String, String, String)] {
        [("paste",  "dict.mode.paste.title",  "dict.mode.paste.desc"),
         ("type",   "dict.mode.type.title",   "dict.mode.type.desc"),
         ("oncall", "dict.mode.oncall.title", "dict.mode.oncall.desc")]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Section caption row (matches a SettingsRow's left column styling).
            VStack(alignment: .leading, spacing: 3) {
                Text(l10n.t("dict.mode"))
                    .font(Vibe.Fonts.ui(13.5, weight: .medium))
                    .foregroundStyle(Vibe.Palette.text(scheme))
                if s.polishOn {
                    Text(l10n.t("dict.mode.lockedByPolish"))
                        .font(Vibe.Fonts.ui(11.5))
                        .foregroundStyle(Vibe.Palette.textMuted(scheme))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 13).padding(.bottom, 6).padding(.horizontal, 16)

            VStack(spacing: 8) {
                ForEach(modes, id: \.0) { mode in
                    // AI 润色开启时,只有「说完插入」可选;另两个置灰、点击弹切换提示。
                    let locked = s.polishOn && mode.0 != "paste"
                    DictationModeRow(
                        title: l10n.t(mode.1),
                        desc: l10n.t(mode.2),
                        badge: mode.0 == "paste" ? l10n.t("badge.recommended") : nil,
                        locked: locked,
                        selected: s.insert == mode.0
                    ) {
                        if locked { pendingMode = mode.0 } else { s.applyInsert(mode.0) }
                    }
                }
            }
            .padding(.horizontal, 16).padding(.bottom, 13)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Vibe.Palette.surface(scheme))
        .alert(l10n.t("dict.mode.conflict.title"),
               isPresented: Binding(get: { pendingMode != nil },
                                    set: { if !$0 { pendingMode = nil } })) {
            Button(l10n.t("dict.mode.conflict.switch"), role: .destructive) {
                if let m = pendingMode { switchOffPolish(then: m) }
                pendingMode = nil
            }
            Button(l10n.t("llm.cancel"), role: .cancel) { pendingMode = nil }
        } message: {
            Text(l10n.t("dict.mode.conflict.msg"))
        }
    }

    /// 关闭 AI 润色(云端 + 本地)后切到目标听写模式。
    private func switchOffPolish(then mode: String) {
        if s.cloud.enabled { var c = s.cloud; c.enabled = false; s.applyCloud(c) }
        if s.refiner { s.applyRefiner(false) }
        s.applyInsert(mode)
    }
}

/// One tappable dictation-mode option: title + long description, with a selected
/// ring + checkmark. The whole row is the hit target.
private struct DictationModeRow: View {
    @Environment(\.colorScheme) private var scheme
    var title: String
    var desc: String
    var badge: String? = nil
    var locked: Bool = false
    var selected: Bool
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 11) {
                // Radio dot.
                ZStack {
                    Circle()
                        .strokeBorder(selected ? Vibe.Palette.accentA
                                               : Vibe.Palette.hairline(scheme),
                                      lineWidth: selected ? 5 : 1.5)
                        .frame(width: 18, height: 18)
                    if selected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
                .padding(.top, 1)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 7) {
                        Text(title)
                            .font(Vibe.Fonts.ui(13, weight: .semibold))
                            .foregroundStyle(Vibe.Palette.text(scheme))
                        if let badge {
                            Text(badge).font(Vibe.Fonts.ui(10, weight: .semibold))
                                .foregroundStyle(Color(red: 0.62, green: 0.58, blue: 1))
                                .padding(.horizontal, 7).padding(.vertical, 2)
                                .background(Capsule().fill(Color(red: 0.55, green: 0.48, blue: 0.94).opacity(0.16)))
                        }
                        if locked {
                            Image(systemName: "lock.fill")
                                .font(.system(size: 9.5))
                                .foregroundStyle(Vibe.Palette.textMuted(scheme))
                        }
                    }
                    Text(desc)
                        .font(Vibe.Fonts.ui(11.5))
                        .foregroundStyle(Vibe.Palette.textMuted(scheme))
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 11).padding(.horizontal, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(selected ? Vibe.Palette.accentSoft(scheme)
                                   : Vibe.Palette.surface2(scheme))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(selected ? Vibe.Palette.accentA
                                           : Vibe.Palette.hairline(scheme),
                                  lineWidth: selected ? 1.5 : 1)
            )
            .opacity(locked ? 0.5 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct DictationTab: View {
    @ObservedObject var s: SettingsState
    @ObservedObject var l10n: L10n
    @Environment(\.colorScheme) private var scheme
    /// Switches the host's settings tab to the Permissions tab.
    var onOpenPermissions: () -> Void
    var body: some View {
        VStack(spacing: 18) {
        SettingsGroup(label: l10n.t("grp.dictation")) {
            SettingsRow(title: l10n.t("dict.clipOverwrite"), help: l10n.t("dict.clipOverwrite.help")) {
                VibeToggle(on: Binding(get: { s.clipOverwrite }, set: { s.applyClipOverwrite($0) }))
            }
            SettingsRow(title: l10n.t("dict.toTraditional"), help: l10n.t("dict.toTraditional.help")) {
                VibeToggle(on: Binding(get: { s.toTraditional }, set: { s.applyToTraditional($0) }))
            }
            SettingsRow(title: l10n.t("dict.hudStay"), help: l10n.t("dict.hudStay.help")) {
                VibeSegmented(value: Binding(
                    get: {
                        let v = s.hudStay
                        if v <= 0.25 { return "0" }
                        if v <= 0.75 { return "0.5" }
                        if v <= 1.5 { return "1" }
                        if v <= 3 { return "2" }
                        return "4"
                    },
                    set: { s.applyHudStay(Double($0) ?? 1.0) }),
                    options: [("0", l10n.t("dict.hudStay.s0")),
                              ("0.5", l10n.t("dict.hudStay.s05")),
                              ("1", l10n.t("dict.hudStay.s1")),
                              ("2", l10n.t("dict.hudStay.s2")),
                              ("4", l10n.t("dict.hudStay.s4"))])
            }
            SettingsRow(title: l10n.t("dict.history"), help: l10n.t("dict.history.help")) {
                VibeToggle(on: Binding(get: { s.history }, set: { s.applyHistory($0) }))
            }
            // 开启「大模型」润色(本地或云端)时,数字规整 + 去口水词由它接管 → 置灰(互斥,不重复做)。
            SettingsRow(title: l10n.t("dict.itn"),
                        help: s.polishOn ? l10n.t("dict.byLLM") : l10n.t("dict.itn.help")) {
                VibeToggle(on: Binding(get: { s.itn }, set: { s.applyItn($0) }))
            }
            .disabled(s.polishOn)
            .opacity(s.polishOn ? 0.5 : 1)
            SettingsRow(title: l10n.t("dict.defiller"),
                        help: s.polishOn ? l10n.t("dict.defiller.byLLM") : l10n.t("dict.defiller.help")) {
                VibeToggle(on: Binding(get: { s.defiller }, set: { s.applyDefiller($0) }))
            }
            .disabled(s.polishOn)
            .opacity(s.polishOn ? 0.5 : 1)
            // Subtle cue sound on dictation start/stop (default on) + timbre.
            SettingsRow(title: l10n.t("dict.cue"), help: l10n.t("dict.cue.help")) {
                VibeToggle(on: Binding(get: { s.cueEnabled }, set: { s.applyCueEnabled($0) }))
            }
            if s.cueEnabled {
                SettingsRow(title: l10n.t("dict.cueTheme"), help: l10n.t("dict.cueTheme.help")) {
                    VibeSelect(value: Binding(get: { s.cueTheme }, set: { _ in }),
                               options: [
                                   ("tick",    l10n.t("cue.tick")),
                                   ("chime",   l10n.t("cue.chime")),
                                   ("soft",    l10n.t("cue.soft")),
                                   ("drop",    l10n.t("cue.drop")),
                                   ("marimba", l10n.t("cue.marimba")),
                               ],
                               onChange: { s.applyCueTheme($0) })
                }
                SettingsRow(title: l10n.t("dict.cueVol"), help: l10n.t("dict.cueVol.help")) {
                    VibeSegmented(value: Binding(get: { s.cueVolume }, set: { _ in }),
                                  options: [("low", l10n.t("vol.low")),
                                            ("med", l10n.t("vol.mid")),
                                            ("high", l10n.t("vol.high"))],
                                  onChange: { s.applyCueVolume($0) })
                }
            }
        }
        }
    }
}

// ---- AI 功能 tab —— 完整实现在 CloudLLMTab.swift(本地润色 + 云端大模型)。

// ---- Hotwords tab (contextual biasing) ------------------------------------

/// (热词 / Hotwords) Edit a list of words the recognizer should be biased toward.
/// The list is edited in a local draft and only committed (→ engine rebuild) on
/// "Save & apply", so typing doesn't thrash the engine. A master switch gates the
/// whole feature; when off the engine stays on the plain greedy recipe.
private struct HotwordsTab: View {
    @ObservedObject var s: SettingsState
    @ObservedObject var l10n: L10n
    @Environment(\.colorScheme) private var scheme

    @State private var hwRows: [HotwordRow] = []   // hotword list (table rows)
    @State private var scoreTier = "mid"   // "low" | "mid" | "high"
    @State private var loaded = false
    @State private var savedFlash = false
    @State private var rRules: [ReplaceRow] = []  // replacement rules (table rows)
    @State private var rSaved = false
    @State private var swapping = false
    @State private var hwPage = 0          // hotword list page
    @State private var rPage = 0           // replacement list page
    private let pageSize = 5
    private let maxWords = 100
    private let maxRules = 100
    private let swapPoll = Timer.publish(every: 0.4, on: .main, in: .common).autoconnect()

    /// boost score ↔ preset tier mapping (3 / 5 / 7 — the CJK boost; English is
    /// auto-capped lower in HotwordsStore since over-boosting English distorts).
    private static func tier(for score: Double) -> String {
        if score < 4 { return "low" }
        if score < 6 { return "mid" }
        return "high"
    }
    private static func score(for tier: String) -> Double {
        switch tier { case "low": return 3.0; case "high": return 7.0; default: return 5.0 }
    }

    private func pageCount(_ n: Int) -> Int { max(1, (n + pageSize - 1) / pageSize) }

    /// ‹ 1 / N › pager, shown only when there's more than one page.
    @ViewBuilder
    private func pager(_ page: Binding<Int>, count: Int) -> some View {
        let pc = pageCount(count)
        if pc > 1 {
            let p = min(max(page.wrappedValue, 0), pc - 1)
            HStack(spacing: 18) {
                Spacer()
                Button { page.wrappedValue = max(0, p - 1) } label: {
                    Image(systemName: "chevron.left").font(.system(size: 12, weight: .semibold))
                }.buttonStyle(.plain).disabled(p == 0).opacity(p == 0 ? 0.3 : 1)
                Text("\(p + 1) / \(pc)").font(Vibe.Fonts.mono(11)).foregroundStyle(Vibe.Palette.textMuted(scheme))
                Button { page.wrappedValue = min(pc - 1, p + 1) } label: {
                    Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold))
                }.buttonStyle(.plain).disabled(p >= pc - 1).opacity(p >= pc - 1 ? 0.3 : 1)
                Spacer()
            }
            .foregroundStyle(Vibe.Palette.accentA)
            .padding(.top, 8).padding(.horizontal, 16)
        }
    }

    /// Parse stored newline-separated hotwords into table rows.
    static func parseHWRows(_ text: String) -> [HotwordRow] {
        text.split(whereSeparator: \.isNewline).compactMap { raw -> HotwordRow? in
            let w = raw.trimmingCharacters(in: .whitespaces)
            return w.isEmpty || w.hasPrefix("#") ? nil : HotwordRow(word: w)
        }
    }
    static func serializeHWRows(_ rows: [HotwordRow]) -> String {
        rows.filter { !$0.word.isEmpty }.map { $0.word }.joined(separator: "\n")
    }
    private var hotwordCount: Int { hwRows.filter { !$0.word.isEmpty }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if swapping { SwitchingBanner(l10n: l10n) }

            SettingsGroup(label: l10n.t("grp.hotwords")) {
                SettingsRow(title: l10n.t("hw.enable"), help: l10n.t("hw.enable.help")) {
                    VibeToggle(on: Binding(get: { s.hotwordsEnabled },
                                           set: { s.applyHotwordsEnabled($0) }))
                }
                editor
                SettingsRow(title: l10n.t("hw.score"), help: l10n.t("hw.score.help")) {
                    VibeSegmented(value: $scoreTier,
                                  options: [("low", l10n.t("hw.score.low")),
                                            ("mid", l10n.t("hw.score.mid")),
                                            ("high", l10n.t("hw.score.high"))])
                }
                SettingsRow(title: l10n.t("hw.pinyin"), help: l10n.t("hw.pinyin.help")) {
                    VibeToggle(on: Binding(get: { s.pinyinFuzzy },
                                           set: { s.applyPinyinFuzzy($0) }))
                }
                saveRow
            }
            SettingsGroup(label: l10n.t("grp.replace")) {
                SettingsRow(title: l10n.t("rep.enable"), help: l10n.t("rep.enable.help")) {
                    VibeToggle(on: Binding(get: { s.replacementsEnabled },
                                           set: { s.applyReplacementsEnabled($0) }))
                }
                replaceEditor
                replaceSaveRow
            }
        }
        .onAppear {
            if !loaded {
                hwRows = HotwordsTab.parseHWRows(s.hotwordsText)
                scoreTier = Self.tier(for: s.hotwordsScore)
                rRules = HotwordsTab.parseRows(s.replacementsText)
                loaded = true
            }
            swapping = s.engineSwapping
        }
        .onReceive(swapPoll) { _ in
            let now = s.engineSwapping
            if now != swapping { withAnimation(Vibe.Motion.easeOut) { swapping = now } }
        }
    }

    /// Single-column table: one hotword per row, add/delete.
    private var editor: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text(l10n.t("hw.editor.title"))
                    .font(Vibe.Fonts.ui(13.5, weight: .medium))
                    .foregroundStyle(Vibe.Palette.text(scheme))
                Text(l10n.t("hw.editor.help"))
                    .font(Vibe.Fonts.ui(11.5))
                    .foregroundStyle(Vibe.Palette.textMuted(scheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 13).padding(.bottom, 8).padding(.horizontal, 16)

            VStack(spacing: 5) {
                if hwRows.isEmpty {
                    Text(l10n.t("hw.empty.hint"))
                        .font(Vibe.Fonts.mono(11.5))
                        .foregroundStyle(Vibe.Palette.textMuted(scheme))
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 12)
                } else {
                    let pi = min(hwPage, pageCount(hwRows.count) - 1)
                    let lo = pi * pageSize
                    let hi = min(lo + pageSize, hwRows.count)
                    ForEach(Array(lo..<hi), id: \.self) { i in
                        HotwordRuleRow(row: $hwRows[i]) {
                            hwRows.remove(at: i)
                            hwPage = min(hwPage, pageCount(hwRows.count) - 1)
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .disabled(!s.hotwordsEnabled)
            .opacity(s.hotwordsEnabled ? 1 : 0.5)

            pager($hwPage, count: hwRows.count)

            Button {
                guard hwRows.count < maxWords else { return }
                hwRows.append(HotwordRow())
                hwPage = pageCount(hwRows.count) - 1
            } label: {
                Label(hwRows.count >= maxWords ? l10n.t("hw.full") : l10n.t("hw.add"), systemImage: "plus.circle")
                    .font(Vibe.Fonts.ui(12.5))
                    .foregroundStyle((s.hotwordsEnabled && hwRows.count < maxWords) ? Vibe.Palette.accentA : Vibe.Palette.textMuted(scheme))
            }
            .buttonStyle(.plain)
            .disabled(!s.hotwordsEnabled || hwRows.count >= maxWords)
            .padding(.horizontal, 16).padding(.top, 9).padding(.bottom, 6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Vibe.Palette.surface(scheme))
    }

    private var saveRow: some View {
        HStack(spacing: 12) {
            Text(String(format: l10n.t("hw.count"), hotwordCount))
                .font(Vibe.Fonts.mono(11.5))
                .foregroundStyle(Vibe.Palette.textMuted(scheme))
            Spacer(minLength: 8)
            if savedFlash {
                Text(l10n.t("hw.saved"))
                    .font(Vibe.Fonts.ui(12, weight: .medium))
                    .foregroundStyle(Vibe.Palette.success)
            }
            MButton(title: l10n.t("io.export"), kind: .ghost) {
                LexiconIO.export(Self.serializeHWRows(hwRows), suggestedName: "vibe-hotwords.txt")
            }
            MButton(title: l10n.t("io.import"), kind: .ghost) {
                if let t = LexiconIO.importText() {
                    hwRows = Self.parseHWRows(t)
                    s.applyHotwords(text: Self.serializeHWRows(hwRows), score: Self.score(for: scoreTier))
                }
            }
            MButton(title: l10n.t("hw.save"), kind: .solid) {
                s.applyHotwords(text: Self.serializeHWRows(hwRows), score: Self.score(for: scoreTier))
                withAnimation { savedFlash = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                    withAnimation { savedFlash = false }
                }
            }
            .disabled(!s.hotwordsEnabled)
        }
        .padding(.vertical, 13).padding(.horizontal, 16)
        .background(Vibe.Palette.surface(scheme))
    }

    /// Parse stored "from => to" text into table rows.
    static func parseRows(_ text: String) -> [ReplaceRow] {
        text.split(whereSeparator: \.isNewline).compactMap { raw -> ReplaceRow? in
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { return nil }
            guard let sep = line.range(of: "=>") ?? line.range(of: "->") else { return nil }
            let from = String(line[..<sep.lowerBound]).trimmingCharacters(in: .whitespaces)
            let to   = String(line[sep.upperBound...]).trimmingCharacters(in: .whitespaces)
            guard !from.isEmpty else { return nil }
            return ReplaceRow(from: from, to: to)
        }
    }
    /// Serialize table rows back to "from => to" storage format.
    static func serializeRows(_ rows: [ReplaceRow]) -> String {
        rows.filter { !$0.from.isEmpty }.map { "\($0.from) => \($0.to)" }.joined(separator: "\n")
    }
    private var ruleCount: Int { rRules.filter { !$0.from.isEmpty }.count }

    /// Two-column table editor (from → to), one row per rule.
    private var replaceEditor: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Section title + help
            VStack(alignment: .leading, spacing: 3) {
                Text(l10n.t("rep.editor.title"))
                    .font(Vibe.Fonts.ui(13.5, weight: .medium))
                    .foregroundStyle(Vibe.Palette.text(scheme))
                Text(l10n.t("rep.editor.help"))
                    .font(Vibe.Fonts.ui(11.5))
                    .foregroundStyle(Vibe.Palette.textMuted(scheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 13).padding(.bottom, 8).padding(.horizontal, 16)

            // Column headers
            HStack(spacing: 8) {
                Text(l10n.t("rep.col.from")).frame(maxWidth: .infinity, alignment: .leading)
                Spacer().frame(width: 22)
                Text(l10n.t("rep.col.to")).frame(maxWidth: .infinity, alignment: .leading)
                Spacer().frame(width: 28)
            }
            .font(Vibe.Fonts.mono(10))
            .foregroundStyle(Vibe.Palette.textMuted(scheme))
            .padding(.horizontal, 16)
            .padding(.bottom, 5)

            // Rule rows
            VStack(spacing: 5) {
                if rRules.isEmpty {
                    Text(l10n.t("rep.empty.hint"))
                        .font(Vibe.Fonts.mono(11.5))
                        .foregroundStyle(Vibe.Palette.textMuted(scheme))
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 12)
                } else {
                    let pi = min(rPage, pageCount(rRules.count) - 1)
                    let lo = pi * pageSize
                    let hi = min(lo + pageSize, rRules.count)
                    ForEach(Array(lo..<hi), id: \.self) { i in
                        ReplaceRuleRow(row: $rRules[i]) {
                            rRules.remove(at: i)
                            rPage = min(rPage, pageCount(rRules.count) - 1)
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .disabled(!s.replacementsEnabled)
            .opacity(s.replacementsEnabled ? 1 : 0.5)

            pager($rPage, count: rRules.count)

            // Add rule button
            Button {
                guard rRules.count < maxRules else { return }
                rRules.append(ReplaceRow())
                rPage = pageCount(rRules.count) - 1
            } label: {
                Label(rRules.count >= maxRules ? l10n.t("hw.full") : l10n.t("rep.add"), systemImage: "plus.circle")
                    .font(Vibe.Fonts.ui(12.5))
                    .foregroundStyle((s.replacementsEnabled && rRules.count < maxRules) ? Vibe.Palette.accentA : Vibe.Palette.textMuted(scheme))
            }
            .buttonStyle(.plain)
            .disabled(!s.replacementsEnabled || rRules.count >= maxRules)
            .padding(.horizontal, 16).padding(.top, 9).padding(.bottom, 6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Vibe.Palette.surface(scheme))
    }

    private var replaceSaveRow: some View {
        HStack(spacing: 12) {
            Text(String(format: l10n.t("rep.count"), ruleCount))
                .font(Vibe.Fonts.mono(11.5))
                .foregroundStyle(Vibe.Palette.textMuted(scheme))
            Spacer(minLength: 8)
            if rSaved {
                Text(l10n.t("hw.saved"))
                    .font(Vibe.Fonts.ui(12, weight: .medium))
                    .foregroundStyle(Vibe.Palette.success)
            }
            MButton(title: l10n.t("io.export"), kind: .ghost) {
                LexiconIO.export(Self.serializeRows(rRules), suggestedName: "vibe-replacements.txt")
            }
            MButton(title: l10n.t("io.import"), kind: .ghost) {
                if let t = LexiconIO.importText() {
                    rRules = Self.parseRows(t)
                    s.applyReplacements(text: Self.serializeRows(rRules))
                }
            }
            MButton(title: l10n.t("hw.save"), kind: .solid) {
                s.applyReplacements(text: Self.serializeRows(rRules))
                withAnimation { rSaved = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                    withAnimation { rSaved = false }
                }
            }
            .disabled(!s.replacementsEnabled)
        }
        .padding(.vertical, 13).padding(.horizontal, 16)
        .background(Vibe.Palette.surface(scheme))
    }
}

// ---- Snippet tab (voice phrase → expansion) -------------------------------

/// One snippet: a trigger phrase that expands into (possibly multi-line) text.
struct SnippetRow: Identifiable {
    var id = UUID()
    var trigger: String = ""
    var text: String = ""
}

/// (口令 / Snippets) Say a trigger, get a saved block of text — e.g. "我的邮箱"
/// → your address, "许可证头" → a license header. Reuses the replacement engine
/// (trigger → text), edited as a local draft, committed on "Save & apply".
private struct SnippetTab: View {
    @ObservedObject var s: SettingsState
    @ObservedObject var l10n: L10n
    @Environment(\.colorScheme) private var scheme
    @State private var rows: [SnippetRow] = []
    @State private var loaded = false
    @State private var saved = false

    static func parse(_ json: String) -> [SnippetRow] {
        guard let data = json.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: String]] else { return [] }
        return arr.compactMap { d in d["t"].map { SnippetRow(trigger: $0, text: d["x"] ?? "") } }
    }
    static func serialize(_ rows: [SnippetRow]) -> String {
        let arr = rows.filter { !$0.trigger.isEmpty }.map { ["t": $0.trigger, "x": $0.text] }
        guard let data = try? JSONSerialization.data(withJSONObject: arr),
              let str = String(data: data, encoding: .utf8) else { return "[]" }
        return str
    }
    private var count: Int { rows.filter { !$0.trigger.isEmpty }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsGroup(label: l10n.t("grp.snippet")) {
                SettingsRow(title: l10n.t("snip.enable"), help: l10n.t("snip.enable.help")) {
                    VibeToggle(on: Binding(get: { s.snippetsEnabled },
                                           set: { s.applySnippetsEnabled($0) }))
                }
                editor
                saveRow
            }
        }
        .onAppear { if !loaded { rows = SnippetTab.parse(s.snippetsJSON); loaded = true } }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text(l10n.t("snip.editor.title"))
                    .font(Vibe.Fonts.ui(13.5, weight: .medium))
                    .foregroundStyle(Vibe.Palette.text(scheme))
                Text(l10n.t("snip.editor.help"))
                    .font(Vibe.Fonts.ui(11.5))
                    .foregroundStyle(Vibe.Palette.textMuted(scheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 13).padding(.bottom, 8).padding(.horizontal, 16)

            VStack(spacing: 10) {
                if rows.isEmpty {
                    Text(l10n.t("snip.empty"))
                        .font(Vibe.Fonts.mono(11.5))
                        .foregroundStyle(Vibe.Palette.textMuted(scheme))
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 12)
                } else {
                    ForEach($rows) { $row in
                        SnippetCard(row: $row, l10n: l10n) { rows.removeAll { $0.id == row.id } }
                    }
                }
            }
            .padding(.horizontal, 16)
            .disabled(!s.snippetsEnabled)
            .opacity(s.snippetsEnabled ? 1 : 0.5)

            Button { rows.append(SnippetRow()) } label: {
                Label(l10n.t("snip.add"), systemImage: "plus.circle")
                    .font(Vibe.Fonts.ui(12.5))
                    .foregroundStyle(s.snippetsEnabled ? Vibe.Palette.accentA : Vibe.Palette.textMuted(scheme))
            }
            .buttonStyle(.plain)
            .disabled(!s.snippetsEnabled)
            .padding(.horizontal, 16).padding(.top, 9).padding(.bottom, 6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Vibe.Palette.surface(scheme))
    }

    private var saveRow: some View {
        HStack(spacing: 12) {
            Text(String(format: l10n.t("snip.count"), count))
                .font(Vibe.Fonts.mono(11.5))
                .foregroundStyle(Vibe.Palette.textMuted(scheme))
            Spacer(minLength: 8)
            if saved {
                Text(l10n.t("hw.saved"))
                    .font(Vibe.Fonts.ui(12, weight: .medium))
                    .foregroundStyle(Vibe.Palette.success)
            }
            MButton(title: l10n.t("io.export"), kind: .ghost) {
                LexiconIO.export(SnippetTab.serialize(rows), suggestedName: "vibe-snippets.json", json: true)
            }
            MButton(title: l10n.t("io.import"), kind: .ghost) {
                if let t = LexiconIO.importText(json: true) {
                    rows = SnippetTab.parse(t)
                    s.applySnippets(json: SnippetTab.serialize(rows))
                }
            }
            MButton(title: l10n.t("hw.save"), kind: .solid) {
                s.applySnippets(json: SnippetTab.serialize(rows))
                withAnimation { saved = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { withAnimation { saved = false } }
            }
            .disabled(!s.snippetsEnabled)
        }
        .padding(.vertical, 13).padding(.horizontal, 16)
        .background(Vibe.Palette.surface(scheme))
    }
}

/// One snippet card: [trigger field] [⊖] over a multi-line expansion editor.
private struct SnippetCard: View {
    @Environment(\.colorScheme) private var scheme
    @Binding var row: SnippetRow
    @ObservedObject var l10n: L10n
    var onDelete: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                ZStack(alignment: .leading) {
                    if row.trigger.isEmpty {
                        Text(l10n.t("snip.trigger.ph")).font(Vibe.Fonts.mono(12))
                            .foregroundStyle(Vibe.Palette.textMuted(scheme))
                            .padding(.horizontal, 10).allowsHitTesting(false)
                    }
                    TextField("", text: $row.trigger)
                        .font(Vibe.Fonts.mono(12)).foregroundStyle(Vibe.Palette.text(scheme))
                        .textFieldStyle(.plain).padding(.vertical, 7).padding(.horizontal, 10)
                }
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Vibe.Palette.surface(scheme))
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(Vibe.Palette.hairline(scheme), lineWidth: 1)))
                .frame(maxWidth: .infinity)
                Button(action: onDelete) {
                    Image(systemName: "minus.circle.fill").font(.system(size: 17))
                        .foregroundStyle(Vibe.Palette.error.opacity(0.85))
                }.buttonStyle(.plain).frame(width: 28)
            }
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Vibe.Palette.surface(scheme))
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(Vibe.Palette.hairline(scheme), lineWidth: 1))
                if row.text.isEmpty {
                    Text(l10n.t("snip.text.ph")).font(Vibe.Fonts.mono(11.5))
                        .foregroundStyle(Vibe.Palette.textMuted(scheme))
                        .padding(.horizontal, 12).padding(.vertical, 10).allowsHitTesting(false)
                }
                TextEditor(text: $row.text)
                    .font(Vibe.Fonts.mono(12)).foregroundStyle(Vibe.Palette.text(scheme))
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 8).padding(.vertical, 6).frame(height: 64)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Vibe.Palette.surface2(scheme)))
    }
}

/// Data model for one hotword row.
struct HotwordRow: Identifiable {
    var id = UUID()
    var word: String = ""
}

/// Single-field row for the hotword list (word + delete button).
private struct HotwordRuleRow: View {
    @Environment(\.colorScheme) private var scheme
    @Binding var row: HotwordRow
    var onDelete: () -> Void
    var body: some View {
        HStack(spacing: 8) {
            ZStack(alignment: .leading) {
                if row.word.isEmpty {
                    Text("e.g. 贾扬清 / PyTorch")
                        .font(Vibe.Fonts.mono(12))
                        .foregroundStyle(Vibe.Palette.textMuted(scheme))
                        .padding(.horizontal, 10)
                        .allowsHitTesting(false)
                }
                TextField("", text: $row.word)
                    .font(Vibe.Fonts.mono(12))
                    .foregroundStyle(Vibe.Palette.text(scheme))
                    .textFieldStyle(.plain)
                    .padding(.vertical, 7).padding(.horizontal, 10)
            }
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Vibe.Palette.surface2(scheme))
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(Vibe.Palette.hairline(scheme), lineWidth: 1))
            )
            .frame(maxWidth: .infinity)
            Button(action: onDelete) {
                Image(systemName: "minus.circle.fill")
                    .font(.system(size: 17))
                    .foregroundStyle(Vibe.Palette.error.opacity(0.85))
            }
            .buttonStyle(.plain)
            .frame(width: 28)
        }
    }
}

/// Data model for one replacement rule row (from → to).
struct ReplaceRow: Identifiable {
    var id = UUID()
    var from: String = ""
    var to: String = ""
}

/// One row in the replacement table: [from field] → [to field] [delete].
private struct ReplaceRuleRow: View {
    @Environment(\.colorScheme) private var scheme
    @Binding var row: ReplaceRow
    var onDelete: () -> Void
    var body: some View {
        HStack(spacing: 8) {
            field($row.from, placeholder: "识别出的")
            Image(systemName: "arrow.right")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Vibe.Palette.textMuted(scheme))
                .frame(width: 22)
            field($row.to, placeholder: "替换为")
            Button(action: onDelete) {
                Image(systemName: "minus.circle.fill")
                    .font(.system(size: 17))
                    .foregroundStyle(Vibe.Palette.error.opacity(0.85))
            }
            .buttonStyle(.plain)
            .frame(width: 28)
        }
    }
    @ViewBuilder private func field(_ binding: Binding<String>, placeholder: String) -> some View {
        ZStack(alignment: .leading) {
            if binding.wrappedValue.isEmpty {
                Text(placeholder)
                    .font(Vibe.Fonts.mono(12))
                    .foregroundStyle(Vibe.Palette.textMuted(scheme))
                    .padding(.horizontal, 10)
                    .allowsHitTesting(false)
            }
            TextField("", text: binding)
                .font(Vibe.Fonts.mono(12))
                .foregroundStyle(Vibe.Palette.text(scheme))
                .textFieldStyle(.plain)
                .padding(.vertical, 7).padding(.horizontal, 10)
        }
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Vibe.Palette.surface2(scheme))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(Vibe.Palette.hairline(scheme), lineWidth: 1))
        )
        .frame(maxWidth: .infinity)
    }
}

// ---- Model tab (VAD + latency tiers + model management) -------------------

private struct ModelTab: View {
    @ObservedObject var s: SettingsState
    @ObservedObject var l10n: L10n
    @Environment(\.colorScheme) private var scheme
    /// Concrete relay around the erased model manager so SwiftUI re-renders live on
    /// the host's @Published download progress (issue #13). Owned here via
    /// @StateObject so its Combine subscription persists across re-renders.
    @StateObject var relay: ModelManagerRelay
    /// Re-poll the bridge's `engineSwapping` while the tab is visible so the
    /// banner appears/clears promptly (the engine swaps off the download path, so
    /// the manager's own progress updates don't always cover it).
    private let swapPoll = Timer.publish(every: 0.4, on: .main, in: .common).autoconnect()
    @State private var swapping = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // (5) Prominent inline "switching" banner at the TOP of the tab, near
            // the tier selector — replaces the easy-to-miss inline pill.
            if swapping { SwitchingBanner(l10n: l10n) }

            // (1)(2) X-ASR streaming ASR models — the PROMINENT, top section.
            SettingsGroup(label: l10n.t("grp.xasr")) {
                // Headline crediting the core ASR model this app is built around.
                ModelHeadline(l10n: l10n)
                // Download-source chooser: ModelScope (default, faster) vs HuggingFace.
                ModelSourceLine(l10n: l10n, relay: relay)
                // Latency tier: a 2x2 of selectable scenario cards.
                tierPicker
                SettingsRow(title: l10n.t("model.aslang")) {
                    Text(l10n.t("model.aslang.zhen"))
                        .font(Vibe.Fonts.ui(12.5))
                        .foregroundStyle(Vibe.Palette.textMuted(scheme))
                }
            }

            // Per-tier download / use / delete management (still part of the
            // prominent X-ASR section, grouped under "MODEL MANAGEMENT").
            SettingsGroup(label: l10n.t("grp.models")) {
                ForEach(LatencyTier.allCases) { tier in
                    TierModelRow(tier: tier, l10n: l10n, relay: relay,
                                 isActive: s.latency == tier.rawValue) {
                        s.applyTier(tier.rawValue)
                    }
                }
            }

            // (2) VAD — moved BELOW and visually de-emphasized (smaller, muted).
            VadSection(s: s, l10n: l10n)
        }
        .onAppear {
            swapping = s.engineSwapping
        }
        .onReceive(swapPoll) { _ in
            let now = s.engineSwapping
            if now != swapping { withAnimation(Vibe.Motion.easeOut) { swapping = now } }
        }
    }

    private var tierPicker: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsRow(title: l10n.t("model.tier"), help: l10n.t("model.tier.help")) {
                EmptyView()
            }
            // 2x2 scenario grid (each card switches the tier).
            let cols = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]
            LazyVGrid(columns: cols, spacing: 8) {
                ForEach(LatencyTier.allCases) { tier in
                    TierCard(tier: tier, l10n: l10n,
                             selected: s.latency == tier.rawValue,
                             downloaded: relay.isTierDownloaded(tier)) {
                        s.applyTier(tier.rawValue)
                    }
                }
            }
            .padding(.horizontal, 16).padding(.bottom, 14)
            .background(Vibe.Palette.surface(scheme))
        }
    }
}

/// Download-source chooser: a segmented ModelScope / HuggingFace picker plus a
/// tappable link to the chosen mirror's model page. ModelScope is the default
/// (faster, esp. in CN). The choice is read/written through the host's
/// ModelDownloader (reached via `relay.manager as? ModelDownloadSourcing`) and is
/// persisted there; switching mid-download is safe (both mirrors share files).
private struct ModelSourceLine: View {
    @Environment(\.colorScheme) private var scheme
    @ObservedObject var l10n: L10n
    @ObservedObject var relay: ModelManagerRelay

    private var sourcing: ModelDownloadSourcing? { relay.manager as? ModelDownloadSourcing }

    var body: some View {
        let current = sourcing?.source ?? .official
        VStack(alignment: .leading, spacing: 0) {
            SettingsRow(title: l10n.t("model.source"), help: l10n.t("model.source.help")) {
                Picker("", selection: Binding(
                    get: { sourcing?.source ?? .official },
                    set: { sourcing?.source = $0 }
                )) {
                    ForEach(ModelDownloadSource.allCases, id: \.self) { src in
                        Text(src.label).tag(src)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize()
                .disabled(sourcing == nil)
            }
            // The chosen mirror's model page (tappable). 官方加速线路不展示域名(repoDisplay 为空)。
            if !current.repoDisplay.isEmpty {
                HStack(spacing: 0) {
                    Link(destination: current.repoURL) {
                        Text(current.repoDisplay)
                            .font(Vibe.Fonts.mono(11))
                            .foregroundStyle(Vibe.Palette.accentB)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 10)
                .background(Vibe.Palette.surface(scheme))
            }
        }
    }
}

/// A short prominent line crediting the X-ASR zh-en streaming model — sits atop
/// the Model tab so the core ASR contribution reads first.
private struct ModelHeadline: View {
    @Environment(\.colorScheme) private var scheme
    @ObservedObject var l10n: L10n
    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            Text(l10n.t("model.headline.title"))
                .font(Vibe.Fonts.ui(14, weight: .semibold))
                .foregroundStyle(Vibe.accentGradient)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Text(l10n.t("model.headline.repo"))
                .font(Vibe.Fonts.mono(10.5))
                .foregroundStyle(Vibe.Palette.accentB)
                .padding(.vertical, 3).padding(.horizontal, 8)
                .background(Capsule().fill(Vibe.Palette.accentSoft(scheme)))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 12).padding(.horizontal, 16)
        .background(Vibe.Palette.surface(scheme))
    }
}

/// The VAD models, rendered below the ASR section and visually de-emphasized
/// (smaller group label + muted help) so it "doesn't draw much attention".
private struct VadSection: View {
    @ObservedObject var s: SettingsState
    @ObservedObject var l10n: L10n
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        SettingsGroup(label: l10n.t("grp.vad")) {
            SettingsRow(title: l10n.t("model.vad"), help: l10n.t("model.vad.help")) {
                VibeSelect(value: Binding(get: { s.vad }, set: { _ in }),
                           options: [("fire", l10n.t("model.vad.fire")),
                                     ("silero", l10n.t("model.vad.silero"))],
                           onChange: { s.applyVad($0) })
            }
        }
        .opacity(0.82)   // subtly recessed relative to the prominent X-ASR section
    }
}

/// A selectable latency-tier scenario card.
private struct TierCard: View {
    @Environment(\.colorScheme) private var scheme
    var tier: LatencyTier
    @ObservedObject var l10n: L10n
    var selected: Bool
    var downloaded: Bool
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(l10n.t(tier.nameKey))
                        .font(Vibe.Fonts.ui(13, weight: .semibold))
                        .foregroundStyle(Vibe.Palette.text(scheme))
                    if tier.isBundled {
                        Tag(text: l10n.t("model.bundled"))
                    } else if !downloaded {
                        Tag(text: "↓")
                    }
                    Spacer()
                    if selected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(Vibe.Palette.accentA)
                    }
                }
                Text(l10n.t(tier.sceneKey))
                    .font(Vibe.Fonts.ui(11))
                    .foregroundStyle(Vibe.Palette.textMuted(scheme))
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 10).padding(.horizontal, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(selected ? Vibe.Palette.accentSoft(scheme)
                                   : Vibe.Palette.surface2(scheme))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(selected ? Vibe.Palette.accentA
                                           : Vibe.Palette.hairline(scheme),
                                  lineWidth: selected ? 1.5 : 1)
            )
        }
        .buttonStyle(.plain)
    }
}

private struct Tag: View {
    @Environment(\.colorScheme) private var scheme
    var text: String
    var body: some View {
        Text(text)
            .font(Vibe.Fonts.mono(9.5))
            .foregroundStyle(Vibe.Palette.textMuted(scheme))
            .padding(.vertical, 1).padding(.horizontal, 5)
            .background(RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Vibe.Palette.surface(scheme)))
    }
}

/// (5) Prominent switching banner — accent-tinted, full-width, pinned to the top
/// of the Model tab so "切换中…" is impossible to miss (the old inline pill next
/// to the VAD select was easy to overlook).
private struct SwitchingBanner: View {
    @Environment(\.colorScheme) private var scheme
    @ObservedObject var l10n: L10n
    var body: some View {
        HStack(spacing: 9) {
            ProgressView().controlSize(.small)
            Text(l10n.t("model.switching.banner"))
                .font(Vibe.Fonts.ui(13, weight: .semibold))
                .foregroundStyle(Vibe.Palette.accentA)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 11).padding(.horizontal, 14)
        .background(
            RoundedRectangle(cornerRadius: Vibe.Radius.card, style: .continuous)
                .fill(Vibe.Palette.accentSoft(scheme))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Vibe.Radius.card, style: .continuous)
                .strokeBorder(Vibe.Palette.accentA.opacity(0.45), lineWidth: 1)
        )
        .padding(.bottom, 16)
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

/// One row in the model-management list (per tier): name + state + action.
private struct TierModelRow: View {
    @Environment(\.colorScheme) private var scheme
    var tier: LatencyTier
    @ObservedObject var l10n: L10n
    @ObservedObject var relay: ModelManagerRelay
    var isActive: Bool
    var onUse: () -> Void

    var body: some View {
        let progress = relay.downloadProgress(tier)
        let downloaded = relay.isTierDownloaded(tier)
        let failed = relay.didTierFail(tier)
        // 内置 或 CDN 加速 = 量化模型(小);ModelScope / HuggingFace = 全精度(大)。
        let quantized = tier.isBundled || relay.refinerSource == .official
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(String(format: l10n.t("model.tierRow"), l10n.t(tier.nameKey)))
                        .font(Vibe.Fonts.ui(13.5, weight: .medium))
                        .foregroundStyle(Vibe.Palette.text(scheme))
                    if isActive {
                        Text(l10n.t("model.active"))
                            .font(Vibe.Fonts.mono(10))
                            .foregroundStyle(Vibe.Palette.accentB)
                            .padding(.vertical, 2).padding(.horizontal, 6)
                            .background(RoundedRectangle(cornerRadius: 5)
                                .fill(Vibe.Palette.accentSoft(scheme)))
                    }
                    // 内置 或 CDN 加速下载 = 量化模型 → 标「已量化」;ModelScope / HuggingFace(全精度)不显示。
                    if quantized {
                        Text(l10n.t("model.quantized"))
                            .font(Vibe.Fonts.mono(10))
                            .foregroundStyle(Vibe.Palette.success)
                            .padding(.vertical, 2).padding(.horizontal, 6)
                            .background(RoundedRectangle(cornerRadius: 5)
                                .fill(Vibe.Palette.success.opacity(0.14)))
                    }
                }
                if let p = progress {
                    HStack(spacing: 9) {
                        ProgressBar(fraction: p).frame(maxWidth: 180)
                        // Before the first byte (p==0) show "Starting download…" so the
                        // click gives IMMEDIATE visible feedback (issue #13), then the
                        // determinate "Downloading N%" once bytes arrive.
                        Text(p > 0 ? String(format: l10n.t("model.downloading"), Int(p * 100))
                                   : l10n.t("model.dl.starting"))
                            .font(Vibe.Fonts.mono(11))
                            .foregroundStyle(Vibe.Palette.textMuted(scheme))
                    }
                } else {
                    HStack(spacing: 4) {
                        Text((quantized ? tier.approxSizeQuantized : tier.approxSize) + " · ")
                            .foregroundStyle(Vibe.Palette.textMuted(scheme))
                        if failed {
                            Text(l10n.t("model.dl.failed"))
                                .foregroundStyle(Vibe.Palette.error)
                        } else if tier.isBundled {
                            Text(l10n.t("model.bundled")).foregroundStyle(Vibe.Palette.success)
                        } else {
                            Text(downloaded ? l10n.t("model.downloaded") : l10n.t("model.notDownloaded"))
                                .foregroundStyle(downloaded ? Vibe.Palette.success
                                                            : Vibe.Palette.textMuted(scheme))
                        }
                    }
                    .font(Vibe.Fonts.mono(11.5))
                }
            }
            Spacer(minLength: 8)
            action(progress: progress, downloaded: downloaded, failed: failed)
        }
        .padding(.vertical, 13).padding(.horizontal, 16)
        .background(Vibe.Palette.surface(scheme))
    }

    @ViewBuilder
    private func action(progress: Double?, downloaded: Bool, failed: Bool) -> some View {
        if progress != nil {
            MButton(title: l10n.t("cancel"), kind: .ghost) { relay.cancelDownload(tier) }
        } else if failed {
            MButton(title: l10n.t("download"), kind: .solid) { relay.startDownload(tier) }
        } else if downloaded {
            HStack(spacing: 8) {
                if !isActive {
                    MButton(title: l10n.t("model.use"), kind: .solid) { onUse() }
                }
                // The bundled tier can't be deleted (read-only in the bundle).
                if !tier.isBundled {
                    MButton(title: l10n.t("delete"), kind: .danger) {
                        _ = relay.deleteTier(tier)
                    }
                }
            }
        } else {
            MButton(title: l10n.t("download"), kind: .solid) { relay.startDownload(tier) }
        }
    }
}

/// `.bar` / `.bar i` gradient progress bar.
struct ProgressBar: View {
    @Environment(\.colorScheme) private var scheme
    var fraction: Double
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Vibe.Palette.surface2(scheme))
                Capsule().fill(Vibe.accentGradient)
                    .frame(width: max(0, min(1, fraction)) * geo.size.width)
            }
        }
        .frame(height: 5)
    }
}

// ---- Permissions tab (live) ----------------------------------------------

private struct PermissionsTab: View {
    @ObservedObject var s: SettingsState
    @ObservedObject var l10n: L10n
    @Environment(\.colorScheme) private var scheme
    @State private var mic = false
    @State private var a11y = false
    @State private var input = false
    @State private var checking = false
    /// Re-poll while the window is visible.
    private let poll = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()

    private var allOk: Bool { mic && a11y && input }

    var body: some View {
        SettingsGroup(label: l10n.t("grp.permissions")) {
            Banner(ok: allOk, l10n: l10n)
            PermRow(l10n: l10n, key: "perm.mic", granted: mic) { s.openPermission(.microphone) }
            SettingsRow(title: l10n.t("perm.device"), help: l10n.t("perm.device.help")) {
                VibeSelect(value: Binding(get: { s.inputDeviceUID }, set: { _ in }),
                           options: s.inputDevices().map { ($0.uid, $0.name) },
                           onChange: { s.applyInputDevice($0) })
            }
            PermRow(l10n: l10n, key: "perm.a11y", granted: a11y) { s.openPermission(.accessibility) }
            PermRow(l10n: l10n, key: "perm.input", granted: input) { s.openPermission(.inputMonitoring) }
            HStack {
                Spacer()
                MButton(title: checking ? l10n.t("perm.checking") : l10n.t("perm.recheck"),
                        kind: .ghost) {
                    checking = true
                    refresh()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { checking = false }
                }
            }
            .padding(.vertical, 12).padding(.horizontal, 16)
            .background(Vibe.Palette.surface(scheme))
        }
        .onAppear(perform: refresh)
        .onReceive(poll) { _ in refresh() }
    }

    private func refresh() {
        mic = s.micGranted()
        a11y = s.a11yGranted()
        input = s.inputGranted()
    }
}

/// A single permission row (status pill + "open settings" when not granted).
/// Takes a plain `onOpen` closure so its body never reaches through the parent's
/// @ObservedObject — which otherwise confuses Swift's closure type inference.
private struct PermRow: View {
    @ObservedObject var l10n: L10n
    var key: String
    var granted: Bool
    var onOpen: () -> Void
    var body: some View {
        SettingsRow(title: l10n.t(key), help: l10n.t(key + ".help")) {
            HStack(spacing: 10) {
                StatusPill(ok: granted)
                if !granted {
                    MButton(title: l10n.t("perm.openSettings"), kind: .solid, action: onOpen)
                }
            }
        }
    }
}

/// `.banner.warn / .banner.ok` advisory banner.
private struct Banner: View {
    var ok: Bool
    @ObservedObject var l10n: L10n
    var body: some View {
        let tint = ok ? Vibe.Palette.success : Vibe.Palette.warn
        let text = ok ? l10n.t("perm.banner.ok") : l10n.t("perm.banner.warn")
        return Text(text)
            .font(Vibe.Fonts.ui(12.5))
            .foregroundStyle(tint)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 11).padding(.horizontal, 14)
            .background(tint.opacity(0.13))
            .overlay(
                Rectangle().fill(tint.opacity(0.30)).frame(height: 1),
                alignment: .bottom)
    }
}

/// (issue #8) The "Records / 记录" sidebar tab. Renders the host-supplied
/// `records` view (an embedded HistoryView) when present; otherwise a centered
/// "No records yet" hint (previews pass nil).
/// (共享) Local share API — a key-protected, read-only local HTTP server so the
/// user's coding agents (Claude Code / Codex / OpenClaw / Hermes …) can read
/// their dictation records / dictionary / snippets and continue work from them.
private struct ShareTab: View {
    @ObservedObject var s: SettingsState
    @ObservedObject var l10n: L10n
    @Environment(\.colorScheme) private var scheme
    @State private var copiedTag: String? = nil

    @State private var actualPort: Int = 0
    private var port: Int { actualPort > 0 ? actualPort : (s.bridge?.apiPort ?? 8473) }
    private var baseURL: String { "http://127.0.0.1:\(port)" }
    private var lanHost: String? { s.bridge?.apiLANHost }

    private struct Agent: Identifiable { let id: String; let name: String; let dir: String? }
    private var agents: [Agent] {
        [.init(id: "openclaw", name: "OpenClaw", dir: ".openclaw/skills/vibe_xasr/"),
         .init(id: "claude",   name: "Claude Code", dir: ".claude/skills/vibe_xasr/"),
         .init(id: "hermes",   name: "Hermes", dir: ".hermes/skills/vibe_xasr/"),
         .init(id: "codex",    name: "Codex", dir: nil),
         .init(id: "generic",  name: l10n.t("share.agent.generic"), dir: nil)]
    }

    var body: some View {
        VStack(spacing: 18) {
            SettingsGroup(label: l10n.t("share.group.title")) {
                SettingsRow(title: l10n.t("share.enable.title"),
                            help: l10n.t("share.enable.help")) {
                    Toggle("", isOn: Binding(get: { s.apiEnabled }, set: { s.applyAPIEnabled($0) })).labelsHidden()
                }
                if s.apiEnabled {
                    SettingsRow(title: l10n.t("share.addr.title"), help: l10n.t("share.addr.help")) {
                        Text(verbatim: baseURL).font(Vibe.Fonts.mono(12))
                            .foregroundStyle(Vibe.Palette.text(scheme)).textSelection(.enabled)
                    }
                    SettingsRow(title: l10n.t("share.key.title"), help: l10n.t("share.key.help")) {
                        HStack(spacing: 8) {
                            Text(s.apiKey).font(Vibe.Fonts.mono(12)).foregroundStyle(Vibe.Palette.text(scheme))
                                .lineLimit(1).truncationMode(.middle).frame(maxWidth: 150)
                            MButton(title: copiedTag == "key" ? l10n.t("share.copied") : l10n.t("share.copy"), kind: .ghost) { copy(s.apiKey, tag: "key") }
                            MButton(title: l10n.t("share.reset"), kind: .danger) { s.regenerateAPIKey() }
                        }
                    }
                    SettingsRow(title: l10n.t("share.lan.title"),
                                help: l10n.t("share.lan.help")) {
                        Toggle("", isOn: Binding(get: { s.apiAllowLAN }, set: { s.applyAPIAllowLAN($0) })).labelsHidden()
                    }
                    if s.apiAllowLAN {
                        SettingsRow(title: l10n.t("share.lanaddr.title"), help: l10n.t("share.lanaddr.help")) {
                            Text(verbatim: lanHost.map { "http://\($0):\(port)" } ?? l10n.t("share.lanaddr.loading"))
                                .font(Vibe.Fonts.mono(12)).foregroundStyle(Vibe.Palette.warn).textSelection(.enabled)
                        }
                    }
                }
            }

            if s.apiEnabled {
                SettingsGroup(label: l10n.t("share.install.group")) {
                    ForEach(agents) { installRow($0) }
                }
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "lock.shield").font(.system(size: 12)).foregroundStyle(Vibe.Palette.success)
                    Text(l10n.t("share.privacy"))
                        .font(Vibe.Fonts.ui(11.5)).foregroundStyle(Vibe.Palette.textMuted(scheme))
                    Spacer()
                }.padding(.horizontal, 2)
            } else {
                Text(l10n.t("share.disabled.hint"))
                    .font(Vibe.Fonts.ui(12)).foregroundStyle(Vibe.Palette.textMuted(scheme))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .task(id: s.apiEnabled) {
            actualPort = 0
            guard s.apiEnabled else { return }
            for _ in 0..<20 {                       // poll until the listener reports its bound port
                if let p = s.bridge?.apiPort, p > 0 { actualPort = p }
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
        }
    }

    private func installRow(_ a: Agent) -> some View {
        let text = instruction(a)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(a.name).font(Vibe.Fonts.ui(13.5, weight: .bold)).foregroundStyle(Vibe.Palette.text(scheme))
                if let d = a.dir { Text(d).font(Vibe.Fonts.mono(11)).foregroundStyle(Vibe.Palette.textMuted(scheme)) }
                Spacer()
                MButton(title: copiedTag == a.id ? l10n.t("share.copied") : l10n.t("share.copyCmd"), kind: .ghost) { copy(text, tag: a.id) }
            }
            Text(verbatim: text).font(Vibe.Fonts.mono(11.5)).foregroundStyle(Vibe.Palette.textMuted(scheme))
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 12).padding(.horizontal, 16)
        .background(Vibe.Palette.surface(scheme))
    }

    private func instruction(_ a: Agent) -> String {
        let key = s.apiKey
        // Templates live in L10n with literal `\(dir)` / `\(key)` / `\(baseURL)`
        // placeholder tokens; fill them in here.
        if let dir = a.dir {
            return l10n.t("share.instr.skill")
                .replacingOccurrences(of: "\\(dir)", with: dir)
                .replacingOccurrences(of: "\\(key)", with: key)
                .replacingOccurrences(of: "\\(baseURL)", with: baseURL)
        }
        return l10n.t("share.instr.generic")
            .replacingOccurrences(of: "\\(baseURL)", with: baseURL)
            .replacingOccurrences(of: "\\(key)", with: key)
    }

    private func copy(_ text: String, tag: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copiedTag = tag
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { if copiedTag == tag { copiedTag = nil } }
    }
}

private struct RecordsTab: View {
    @ObservedObject var l10n: L10n
    @Environment(\.colorScheme) private var scheme
    var records: AnyView?
    var body: some View {
        if let records {
            records.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 10) {
                Spacer()
                Text("📋").font(.system(size: 40)).opacity(0.5)
                Text(l10n.t("records.empty"))
                    .font(Vibe.Fonts.ui(13))
                    .foregroundStyle(Vibe.Palette.textMuted(scheme))
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct AboutTab: View {
    @ObservedObject var l10n: L10n
    weak var bridge: SettingsBridge?
    @Environment(\.colorScheme) private var scheme
    /// Secondary acknowledgments — the supporting OSS stack, shown small/below.
    private let secondaryCredits = ["sherpa-onnx", "FireRedVAD", "onnxruntime",
                                    "kaldi-native-fbank", "silero-vad", "kissfft"]
    var body: some View {
        SettingsGroup {
            VStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Vibe.accentGradient)
                    .frame(width: 64, height: 64)
                    .overlay(LogoBars(heights: [10, 22, 30, 18, 12], barW: 4, gap: 3))
                    .shadow(color: Vibe.Palette.accentA.opacity(0.45), radius: 15, y: 10)
                Text(l10n.t("app.name")).font(Vibe.Fonts.ui(22, weight: .bold))
                    .foregroundStyle(Vibe.Palette.text(scheme))
                Text(String(format: l10n.t("about.version"),
                            Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.1.1"))
                    .font(Vibe.Fonts.mono(11.5))
                    .foregroundStyle(Vibe.Palette.textMuted(scheme))

                // Sparkle update check — drives the host's updater (appcast on GitHub Pages).
                Button { bridge?.checkForUpdates() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                        Text(l10n.t("about.checkUpdate"))
                    }
                    .font(Vibe.Fonts.ui(12, weight: .medium))
                    .foregroundStyle(Vibe.Palette.accentB)
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .background(
                        Capsule().fill(Vibe.Palette.accentB.opacity(0.12))
                    )
                }
                .buttonStyle(.plain)
                .padding(.top, 4)

                // Single feedback channel below "Check for updates": all issues
                // (engine, app, requests) are routed to the X-ASR engine tracker.
                FeedbackLinks(l10n: l10n)
                    .padding(.top, 9)

                // 引导式提交 issue:填「功能 / 问题 / 预期」→ 打开预填好的 GitHub 新建 issue 页。
                FeedbackForm()
                    .padding(.top, 14)

                // (About) BIG, prominent X-ASR credit — the core ASR model this
                // whole app is built around.
                XASRCredit(l10n: l10n)
                    .padding(.top, 22)

                // Secondary acknowledgments — smaller, muted, below the X-ASR card.
                VStack(spacing: 9) {
                    Text(l10n.t("about.credits"))
                        .font(Vibe.Fonts.mono(10.5)).tracking(1.1)
                        .foregroundStyle(Vibe.Palette.textMuted(scheme))
                    // Wrapping flow of small chips (6 items won't fit one row).
                    FlowChips(items: secondaryCredits)
                }
                .padding(.top, 22)

                Text(l10n.t("about.local"))
                    .font(Vibe.Fonts.mono(11))
                    .foregroundStyle(Vibe.Palette.textMuted(scheme))
                    .padding(.top, 18)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 36).padding(.horizontal, 24)
            .background(Vibe.Palette.surface(scheme))
        }
    }
}

/// 引导式提交 issue 的表单:填「使用的功能 / 遇到的问题 / 预期结果」三项,点按钮直接打开
/// 一个已预填标题+正文的 GitHub「新建 issue」页,用户确认即可提交。
private struct FeedbackForm: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.openURL) private var openURL
    @State private var feature = ""
    @State private var problem = ""
    @State private var expected = ""

    private var canSubmit: Bool {
        !(feature + problem + expected).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            Text("反馈问题 · 一键提交到 GitHub")
                .font(Vibe.Fonts.ui(13.5, weight: .semibold)).foregroundStyle(Vibe.Palette.text(scheme))
            Text("填好下面三项，点按钮会打开已预填内容的 GitHub「新建 issue」页，确认后提交即可。")
                .font(Vibe.Fonts.ui(11.5)).foregroundStyle(Vibe.Palette.textMuted(scheme))
                .fixedSize(horizontal: false, vertical: true)
            field("使用的功能", "如：云端润色 / 听写插入 / 热词修正", $feature, lines: 1...2)
            field("遇到的问题", "具体现象、什么时候出现、能否复现", $problem, lines: 2...5)
            field("预期结果", "你期望它怎样", $expected, lines: 1...4)
            HStack {
                Spacer()
                Button { submit() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "paperplane.fill").font(.system(size: 11))
                        Text("在 GitHub 提交（已预填）")
                    }
                    .font(Vibe.Fonts.ui(12.5, weight: .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 16).frame(height: 38)
                    .background(RoundedRectangle(cornerRadius: 10)
                        .fill(canSubmit ? Vibe.Palette.accentA : Vibe.Palette.accentA.opacity(0.4)))
                }
                .buttonStyle(.plain).disabled(!canSubmit)
            }
        }
        .multilineTextAlignment(.leading)
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 16).fill(Vibe.Palette.surface2(scheme))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Vibe.Palette.hairline(scheme))))
    }
    private func field(_ label: String, _ placeholder: String, _ text: Binding<String>, lines: ClosedRange<Int>) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(Vibe.Fonts.ui(11.5, weight: .medium)).foregroundStyle(Vibe.Palette.textMuted(scheme))
            TextField(placeholder, text: text, axis: .vertical)
                .textFieldStyle(.plain).font(Vibe.Fonts.ui(13)).lineLimit(lines)
                .padding(.horizontal, 11).padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.22))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Vibe.Palette.hairline(scheme))))
        }
    }
    private func submit() {
        let ver = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        let f = feature.isEmpty ? "(未填)" : feature
        let title = "[反馈] 使用「\(f)」遇到的问题"
        let body = """
        ## 使用的功能 / Feature
        \(feature)

        ## 遇到的问题 / Problem
        \(problem)

        ## 预期结果 / Expected
        \(expected)

        ---
        - Vibe XASR \(ver)
        - \(os)
        """
        var comp = URLComponents(string: "https://github.com/Gilgamesh-J/X-ASR/issues/new")!
        comp.queryItems = [URLQueryItem(name: "title", value: title), URLQueryItem(name: "body", value: body)]
        // URLComponents 不编码 '+'(GitHub 会当空格)→ 手动补上。
        comp.percentEncodedQuery = comp.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        if let url = comp.url { openURL(url) }
    }
}

/// A single feedback channel shown as small text under "Check for updates":
/// all issues — engine bugs, app bugs, and feature requests — are routed to the
/// X-ASR engine tracker (Gilgamesh-J/X-ASR/issues).
private struct FeedbackLinks: View {
    @ObservedObject var l10n: L10n
    @Environment(\.colorScheme) private var scheme
    private let engineURL = URL(string: "https://github.com/Gilgamesh-J/X-ASR/issues")!
    var body: some View {
        VStack(spacing: 6) {
            row(icon: "waveform", text: l10n.t("about.fb.engine"), url: engineURL)
        }
    }
    private func row(icon: String, text: String, url: URL) -> some View {
        Link(destination: url) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 10))
                Text(text)
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 8, weight: .semibold)).opacity(0.7)
            }
            .font(Vibe.Fonts.ui(11))
            .foregroundStyle(Vibe.Palette.textMuted(scheme))
        }
        .buttonStyle(.plain)
        .help(url.absoluteString)
    }
}

/// The headline X-ASR acknowledgment card: large title + one-line description +
/// the HF repo, on an accent-soft surface so it visually leads the About tab.
private struct XASRCredit: View {
    @Environment(\.colorScheme) private var scheme
    @ObservedObject var l10n: L10n
    private let ghURL = URL(string: "https://github.com/Gilgamesh-J/X-ASR")!
    private let hfURL = URL(string: "https://huggingface.co/GilgameshWind/X-ASR-zh-en")!
    var body: some View {
        VStack(spacing: 7) {
            // (issue #7) The X-ASR title opens the GitHub repo.
            Link(destination: ghURL) {
                Text(l10n.t("about.xasr.title"))
                    .font(Vibe.Fonts.ui(19, weight: .bold))
                    .foregroundStyle(Vibe.accentGradient)
                    .multilineTextAlignment(.center)
            }
            Text(l10n.t("about.xasr.desc"))
                .font(Vibe.Fonts.ui(12.5))
                .foregroundStyle(Vibe.Palette.text(scheme))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                Link(destination: ghURL) {
                    Text("github.com/Gilgamesh-J/X-ASR")
                        .font(Vibe.Fonts.mono(11))
                        .foregroundStyle(Vibe.Palette.accentB)
                }
                Link(destination: hfURL) {
                    Text(l10n.t("about.xasr.repo"))
                        .font(Vibe.Fonts.mono(11))
                        .foregroundStyle(Vibe.Palette.accentB)
                }
            }
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18).padding(.horizontal, 18)
        .background(
            RoundedRectangle(cornerRadius: Vibe.Radius.card, style: .continuous)
                .fill(Vibe.Palette.accentSoft(scheme))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Vibe.Radius.card, style: .continuous)
                .strokeBorder(Vibe.Palette.accentA.opacity(0.40), lineWidth: 1)
        )
    }
}

/// A simple wrapping chip flow (small, muted) for the secondary credits. Each chip
/// opens the project's repository (issue #7).
private struct FlowChips: View {
    @Environment(\.colorScheme) private var scheme
    var items: [String]

    /// Map each acknowledged project to its upstream repository URL.
    private func url(for name: String) -> URL? {
        let map: [String: String] = [
            "sherpa-onnx": "https://github.com/k2-fsa/sherpa-onnx",
            "FireRedVAD": "https://github.com/FireRedTeam/FireRedVAD",
            "onnxruntime": "https://github.com/microsoft/onnxruntime",
            "kaldi-native-fbank": "https://github.com/csukuangfj/kaldi-native-fbank",
            "silero-vad": "https://github.com/snakers4/silero-vad",
            "kissfft": "https://github.com/mborgerding/kissfft",
        ]
        return map[name].flatMap(URL.init(string:))
    }

    var body: some View {
        // A fixed 3-column grid wraps cleanly for the ~6 secondary credits and
        // avoids a custom Layout (keeps macOS 13 compatibility).
        let cols = [GridItem(.adaptive(minimum: 96, maximum: 160), spacing: 7)]
        LazyVGrid(columns: cols, alignment: .center, spacing: 7) {
            ForEach(items, id: \.self) { c in
                chip(c)
            }
        }
        .frame(maxWidth: 360)
    }

    @ViewBuilder
    private func chip(_ c: String) -> some View {
        let label = Text(c)
            .font(Vibe.Fonts.ui(11))
            .foregroundStyle(Vibe.Palette.textMuted(scheme))
            .lineLimit(1)
            .padding(.vertical, 5).padding(.horizontal, 10)
            .frame(maxWidth: .infinity)
            .background(Capsule().fill(Vibe.Palette.surface2(scheme)))
            .overlay(Capsule().strokeBorder(Vibe.Palette.hairline(scheme), lineWidth: 1))
        if let u = url(for: c) {
            Link(destination: u) { label }
        } else {
            label
        }
    }
}

/// The white equalizer bars used in the logo tiles.
struct LogoBars: View {
    var heights: [CGFloat]
    var barW: CGFloat
    var gap: CGFloat
    var body: some View {
        HStack(alignment: .center, spacing: gap) {
            ForEach(heights.indices, id: \.self) { i in
                RoundedRectangle(cornerRadius: barW / 2, style: .continuous)
                    .fill(Color.white)
                    .frame(width: barW, height: heights[i])
            }
        }
    }
}

// MARK: - Preferences window shell

public struct SettingsView: View {
    @StateObject private var s = SettingsState()
    @ObservedObject private var l10n = L10n.shared
    @State private var tab = "general"
    /// Live "all permissions granted" flag, polled while the window is open —
    /// drives the red badge on the Permissions sidebar tab.
    @State private var permsOK = true
    @Environment(\.colorScheme) private var scheme

    /// Host bridge for the live (store-backed) controls; nil in previews.
    private let bridge: SettingsBridge?
    /// Concrete model manager (observable) for the Model tab, if the host gave one.
    private let manager: (any ModelManagerBridge & ObservableObject)?
    /// (issue #8) Content for the always-visible "Records" sidebar tab — the host
    /// passes an embedded HistoryView here. Nil in previews → an empty hint shows.
    private let records: AnyView?

    private var tabs: [(id: String, label: String, icon: String)] {
        [("general", l10n.t("tab.general"), "⚙"),
         ("dictation", l10n.t("tab.dictation"), "🎙"),
         ("llm", l10n.t("tab.llm"), "✨"),
         ("model", l10n.t("tab.model"), "🧠"),
         ("hotwords", l10n.t("tab.hotwords"), "📖"),
         ("snippet", l10n.t("tab.snippet"), "⚡"),
         ("records", l10n.t("tab.records"), "📋"),
         ("share", l10n.t("tab.share"), "🔗"),
         ("permissions", l10n.t("tab.permissions"), "🔐"),
         ("about", l10n.t("tab.about"), "ⓘ")]
    }

    public init() { self.bridge = nil; self.manager = nil; self.records = nil }

    /// Host entry point: pass the SettingsStore-backed bridge + (optionally) the
    /// observable model manager so the Model tab shows live download progress, and
    /// the `records` view rendered in the Records sidebar tab.
    public init(bridge: SettingsBridge,
                manager: (any ModelManagerBridge & ObservableObject)? = nil,
                records: AnyView? = nil) {
        self.bridge = bridge
        self.manager = manager
        self.records = records
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                sidebar
                Rectangle().fill(Vibe.Palette.hairline(scheme)).frame(width: 1)
                content
            }
        }
        // Fill the (now resizable) window; the 记录 workspace needs the full width
        // for its calendar rail. Other tabs cap their own content width (see `content`).
        .frame(minWidth: 720, idealWidth: 1080, maxWidth: .infinity,
               minHeight: 520, idealHeight: 680, maxHeight: .infinity)
        .background(Vibe.Palette.surface(scheme))
        // The NATIVE window title bar shows "偏好设置" + the traffic lights on one row
        // (set up in AppDelegate). No custom title strip here — that produced the
        // "two rows" look. Content sits directly below the native title bar.
        .onAppear {
            if let bridge { s.bind(to: bridge) }
            permsOK = s.micGranted() && s.a11yGranted() && s.inputGranted()
        }
        // Poll permissions while the window is open so the sidebar badge clears
        // within ~1.5s of the user granting access in System Settings.
        .onReceive(Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()) { _ in
            permsOK = s.micGranted() && s.a11yGranted() && s.inputGranted()
        }
        // Re-sync the controls when the mode changes programmatically (e.g. stopping
        // OnCall reverts the dictation mode) so the picker isn't left stale.
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("vibeSettingsExternallyChanged"))) { _ in
            if let bridge { s.bind(to: bridge) }
        }
    }

    /// The right-hand pane. Records hosts a self-contained HistoryView (its own
    /// scrolling + frame), so it is rendered WITHOUT the outer padded ScrollView the
    /// other tabs use.
    @ViewBuilder
    private var content: some View {
        if tab == "records" {
            RecordsTab(l10n: l10n, records: records)
                .background(Vibe.Palette.surface(scheme))
        } else {
            ScrollView {
                Group {
                    switch tab {
                    case "general":     GeneralTab(s: s, l10n: l10n,
                                                   onOpenPermissions: { tab = "permissions" })
                    case "dictation":   DictationTab(s: s, l10n: l10n,
                                                     onOpenPermissions: { tab = "permissions" })
                    case "llm":         LLMTab(s: s, l10n: l10n,
                                                relay: ModelManagerRelay(manager))
                    case "model":       ModelTab(s: s, l10n: l10n,
                                                 relay: ModelManagerRelay(manager))
                    case "hotwords":    HotwordsTab(s: s, l10n: l10n)
                    case "snippet":     SnippetTab(s: s, l10n: l10n)
                    case "permissions": PermissionsTab(s: s, l10n: l10n)
                    case "share":       ShareTab(s: s, l10n: l10n)
                    default:            AboutTab(l10n: l10n, bridge: bridge)
                    }
                }
                .padding(.vertical, 22).padding(.horizontal, 24)
                .frame(maxWidth: 680)           // keep these tabs readable in the wide window
                .frame(maxWidth: .infinity)      // …centered
            }
            .background(Vibe.Palette.surface(scheme))
        }
    }

    private var titlebar: some View {
        // (issue #14) The title sits on the SAME row as the native traffic lights,
        // immediately to their right. No separate coloured band / divider — the row
        // is transparent so the title reads as part of the native title bar (28px =
        // the standard title-bar height; ~78px leading clears the three lights).
        HStack(spacing: 0) {
            Text(l10n.t("settings.title"))
                .font(Vibe.Fonts.ui(13, weight: .semibold))
                .foregroundStyle(Vibe.Palette.textMuted(scheme))
                .padding(.leading, 78)
            Spacer(minLength: 0)
        }
        .frame(height: 28)
        .frame(maxWidth: .infinity)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 9) {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Vibe.accentGradient)
                    .frame(width: 22, height: 22)
                    .overlay(LogoBars(heights: [5, 11, 7], barW: 2, gap: 2))
                    .shadow(color: Vibe.Palette.accentA.opacity(0.4), radius: 4, y: 2)
                Text(l10n.t("app.name"))
                    .font(Vibe.Fonts.ui(14, weight: .semibold))
                    .foregroundStyle(Vibe.Palette.text(scheme))
            }
            .padding(.leading, 10).padding(.top, 6).padding(.bottom, 14)

            ForEach(tabs, id: \.id) { t in
                let on = tab == t.id
                Button { tab = t.id } label: {
                    HStack(spacing: 10) {
                        Text(t.icon).font(.system(size: 14)).frame(width: 18)
                        Text(t.label)
                            .font(Vibe.Fonts.ui(13.5, weight: on ? .medium : .regular))
                        Spacer()
                        // Live red badge: a permission is missing. Polled every
                        // ~1.5s, so it clears shortly after the user grants access.
                        if t.id == "permissions" && !permsOK {
                            Image(systemName: "exclamationmark.circle.fill")
                                .font(.system(size: 13))
                                .foregroundStyle(Vibe.Palette.error)
                        }
                    }
                    .foregroundStyle(Vibe.Palette.text(scheme))
                    .padding(.vertical, 8).padding(.horizontal, 10)
                    // BUGFIX (1a): the WHOLE row is the hit target, not just the
                    // label text. The HStack already fills the width (Spacer),
                    // and contentShape(Rectangle()) makes the transparent gaps
                    // tappable so a click anywhere on the row switches tabs.
                    .contentShape(Rectangle())
                    .background(
                        RoundedRectangle(cornerRadius: Vibe.Radius.control, style: .continuous)
                            .fill(on ? Vibe.Palette.accentSoft(scheme) : .clear)
                    )
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .frame(width: 176)
        .padding(.vertical, 14).padding(.horizontal, 10)
        .background(Vibe.Palette.surface(scheme).opacity(0.7))
    }
}

/// macOS traffic-light dots (decorative).
struct TrafficLights: View {
    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(Color(hex: "#FF5F57")).frame(width: 12, height: 12)
            Circle().fill(Color(hex: "#FEBC2E")).frame(width: 12, height: 12)
            Circle().fill(Color(hex: "#28C840")).frame(width: 12, height: 12)
        }
    }
}

// MARK: - Preview (dark)

#Preview("Settings (dark)") {
    SettingsView()
        .padding(40)
        .background(Color(hex: "#0E0E12"))
        .preferredColorScheme(.dark)
}
