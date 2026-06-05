import Foundation
import VibeUI

/// Single source of truth for user-configurable app settings, backed by
/// `UserDefaults`. All keys live under the app's standard suite
/// (`com.xasr.vibexasr`), so the AppDelegate, the SwiftUI Settings window and
/// the onboarding wizard all observe/mutate the same store.
///
/// Keys:
///   * `showDockIcon`          Bool   (default true)   — Dock icon + Launchpad presence.
///   * `hotkeyKeyCode`         Int    (default 54)     — push-to-talk virtual keycode.
///   * `hotkeyModifierOnly`    Bool   (default true)   — is the hotkey a modifier key?
///   * `didCompleteOnboarding` Bool   (default false)  — first-run wizard finished?
///   * `vadKind`               String (default "fire") — "fire" | "silero".
///   * `latencyTier`           Int    (default 960)    — streaming chunk model ms.
///   * `appLanguage`           String (default "auto") — UI language (auto/zh/en/ja/ko).
///   * `padWriteEnabled`       Bool   (default false)  — append finals into the Pad.
///   * `historyEnabled`        Bool   (default true)   — persist finals to history.json.
///   * `insertMethod`          String (default "paste")— "paste" | "type".
///   * `launchAtLogin`         Bool   (default false)  — register a login item.
///
/// Mutations post `SettingsStore.changed` (and more specific notifications) so
/// observers can react live.
@MainActor
final class SettingsStore: L10nPersistence {

    static let shared = SettingsStore()

    /// Posted on any settings mutation routed through this store.
    static let changed = Notification.Name("VibeXASR.settingsChanged")
    /// Posted specifically when the push-to-talk hotkey changes.
    static let hotkeyChanged = Notification.Name("VibeXASR.hotkeyChanged")
    /// Posted when the Dock-icon preference changes.
    static let dockIconChanged = Notification.Name("VibeXASR.dockIconChanged")
    /// Posted when the engine configuration (VAD kind or latency tier) changes,
    /// so the AppDelegate can rebuild the engine off the audio path.
    static let engineConfigChanged = Notification.Name("VibeXASR.engineConfigChanged")
    /// Posted when the launch-at-login preference changes.
    static let launchAtLoginChanged = Notification.Name("VibeXASR.launchAtLoginChanged")
    /// Posted when the local share API config changes (enable / LAN / key / port),
    /// so the AppDelegate can (re)start or stop the embedded HTTP server.
    static let apiConfigChanged = Notification.Name("VibeXASR.apiConfigChanged")

    private enum Key {
        static let showDockIcon = "showDockIcon"
        static let hotkeyKeyCode = "hotkeyKeyCode"
        static let hotkeyModifierOnly = "hotkeyModifierOnly"
        static let didCompleteOnboarding = "didCompleteOnboarding"
        static let vadKind = "vadKind"
        static let latencyTier = "latencyTier"
        static let appLanguage = "appLanguage"
        static let padWriteEnabled = "padWriteEnabled"
        static let historyEnabled = "historyEnabled"
        static let insertMethod = "insertMethod"
        static let clipboardOverwrite = "clipboardOverwrite"
        static let launchAtLogin = "launchAtLogin"
        static let cueEnabled = "cueEnabled"
        static let cueTheme = "cueTheme"
        static let cueVolume = "cueVolume"
        static let hotwordsEnabled = "hotwordsEnabled"
        static let hotwordsText = "hotwordsText"
        static let hotwordsScore = "hotwordsScore"
        static let replacementsEnabled = "replacementsEnabled"
        static let replacementsText = "replacementsText"
        static let pinyinFuzzyEnabled = "pinyinFuzzyEnabled"
        static let itnEnabled = "itnEnabled"
        static let defillerEnabled = "defillerEnabled"
        static let refinerEnabled = "refinerEnabled"
        // 云端大模型
        static let cloudEnabled = "cloudEnabled"
        static let cloudProvider = "cloudProvider"
        static let cloudBaseURL = "cloudBaseURL"
        static let cloudModel = "cloudModel"
        static let cloudModNumbers = "cloudModNumbers"
        static let cloudModFillers = "cloudModFillers"
        static let cloudModRestate = "cloudModRestate"
        static let cloudModHotwords = "cloudModHotwords"
        static let cloudTemplatesJSON = "cloudTemplatesJSON"
        static let cloudActiveTemplate = "cloudActiveTemplate"
        static let cloudAutoOverride = "cloudAutoOverride"
        static let cloudCustomProvidersJSON = "cloudCustomProvidersJSON"
        static let cloudTemperature = "cloudTemperature"
        static let cloudMaxTokens = "cloudMaxTokens"
        static let cloudLogEnabled = "cloudLogEnabled"
        static let inputDeviceUID = "inputDeviceUID"
        static let snippetsEnabled = "snippetsEnabled"
        static let snippetsJSON = "snippetsJSON"
        static let apiEnabled = "apiEnabled"
        static let apiKey = "apiKey"
        static let apiAllowLAN = "apiAllowLAN"
        static let apiPort = "apiPort"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.showDockIcon: true,
            Key.hotkeyKeyCode: 54,            // Right ⌘
            Key.hotkeyModifierOnly: true,
            Key.didCompleteOnboarding: false,
            Key.vadKind: "fire",
            Key.latencyTier: 960,
            Key.appLanguage: "auto",
            Key.padWriteEnabled: false,
            Key.historyEnabled: true,
            Key.insertMethod: "type",   // default to streaming keystroke insertion
            Key.clipboardOverwrite: false,
            Key.launchAtLogin: false,
            Key.cueEnabled: true,             // Typeless-style cue sound, ON by default
            Key.cueTheme: "chime",            // default timbre
            Key.cueVolume: "low",             // cue volume: low (default) | med | high
            Key.hotwordsEnabled: false,       // hotword biasing OFF by default (zero regression)
            // Pre-populated examples: common AI names/terms users can keep or swap out.
            Key.hotwordsText: "贾扬清\n沈向洋\nPyTorch\nOpenAI\ntransformer\n向量数据库",
            Key.hotwordsScore: 5.0,           // "mid" boost (CJK; English auto-capped ≤2.5)
            Key.replacementsEnabled: false,   // post-recognition corrections OFF by default
            Key.replacementsText: "",
            Key.pinyinFuzzyEnabled: true,     // homophone (pinyin) correction ON by default
            Key.itnEnabled: true,             // number normalization (ITN) ON by default
            Key.defillerEnabled: true,        // filler-word removal (嗯/呃/repeats) ON by default
            Key.refinerEnabled: false,        // AI 润色(Beta) OFF by default — zero regression until opted in
            Key.cloudEnabled: false,          // 云端大模型 OFF by default(需用户配 Key)
            Key.cloudProvider: "openai",
            Key.cloudBaseURL: "https://api.openai.com/v1",
            Key.cloudModel: "gpt-4o-mini",
            Key.cloudModNumbers: true,
            Key.cloudModFillers: true,
            Key.cloudModRestate: true,
            Key.cloudModHotwords: true,
            Key.cloudTemplatesJSON: "",
            Key.cloudActiveTemplate: "auto",
            Key.cloudAutoOverride: "",
            Key.inputDeviceUID: "",           // "" = system default microphone
            Key.snippetsEnabled: true,        // voice snippets ON by default (empty list = no-op)
            Key.snippetsJSON: "[]",
            Key.apiEnabled: false,            // local share API OFF by default
            Key.apiAllowLAN: false,           // localhost-only unless explicitly allowed
            Key.apiPort: 8473,                // default port for the local share API (uncommon → fewer conflicts)
        ])
    }

    // MARK: Dock icon

    var showDockIcon: Bool {
        get { defaults.bool(forKey: Key.showDockIcon) }
        set {
            defaults.set(newValue, forKey: Key.showDockIcon)
            post(SettingsStore.dockIconChanged)
        }
    }

    // MARK: Push-to-talk hotkey

    var hotkeyKeyCode: Int {
        get { defaults.integer(forKey: Key.hotkeyKeyCode) }
        set { defaults.set(newValue, forKey: Key.hotkeyKeyCode) }
    }

    var hotkeyModifierOnly: Bool {
        get { defaults.bool(forKey: Key.hotkeyModifierOnly) }
        set { defaults.set(newValue, forKey: Key.hotkeyModifierOnly) }
    }

    /// Update the hotkey atomically and notify observers.
    func setHotkey(keyCode: Int, modifierOnly: Bool) {
        defaults.set(keyCode, forKey: Key.hotkeyKeyCode)
        defaults.set(modifierOnly, forKey: Key.hotkeyModifierOnly)
        post(SettingsStore.hotkeyChanged)
    }

    // MARK: Onboarding

    var didCompleteOnboarding: Bool {
        get { defaults.bool(forKey: Key.didCompleteOnboarding) }
        set {
            defaults.set(newValue, forKey: Key.didCompleteOnboarding)
            post(SettingsStore.changed)
        }
    }

    // MARK: VAD + latency tier (engine config)

    /// "fire" (FireRedVAD, default) or "silero".
    var vadKind: String {
        get { defaults.string(forKey: Key.vadKind) ?? "fire" }
        set {
            guard newValue != vadKind else { return }
            defaults.set(newValue, forKey: Key.vadKind)
            post(SettingsStore.engineConfigChanged)
        }
    }

    /// Streaming chunk model size in ms (160/480/960/1920). Defaults to 960.
    var latencyTier: Int {
        get {
            let v = defaults.integer(forKey: Key.latencyTier)
            return LatencyTier(rawValue: v) != nil ? v : 960
        }
        set {
            guard newValue != latencyTier, LatencyTier(rawValue: newValue) != nil else { return }
            defaults.set(newValue, forKey: Key.latencyTier)
            post(SettingsStore.engineConfigChanged)
        }
    }

    var latencyTierEnum: LatencyTier { LatencyTier(rawValue: latencyTier) ?? .ms960 }

    // MARK: UI language (L10nPersistence)

    /// Raw language choice (auto/zh/en/ja/ko). Conforms to `L10nPersistence` so
    /// VibeUI's `L10n` can read/write it without importing this type.
    var storedLang: String {
        get { defaults.string(forKey: Key.appLanguage) ?? "auto" }
        set {
            defaults.set(newValue, forKey: Key.appLanguage)
            post(SettingsStore.changed)
        }
    }

    // MARK: Pad / History

    /// When on, every dictation final is appended to the built-in Pad.
    var padWriteEnabled: Bool {
        get { defaults.bool(forKey: Key.padWriteEnabled) }
        set { defaults.set(newValue, forKey: Key.padWriteEnabled); post(SettingsStore.changed) }
    }

    /// When on, every dictation final is persisted to history.json.
    var historyEnabled: Bool {
        get { defaults.bool(forKey: Key.historyEnabled) }
        set { defaults.set(newValue, forKey: Key.historyEnabled); post(SettingsStore.changed) }
    }

    // MARK: Insert method

    /// "paste" (clipboard + ⌘V) or "type" (synthesize keystrokes).
    var insertMethod: String {
        get { defaults.string(forKey: Key.insertMethod) ?? "type" }
        set { defaults.set(newValue, forKey: Key.insertMethod); post(SettingsStore.changed) }
    }

    /// When on, each dictation also overwrites the system clipboard with the final
    /// text (so it can be pasted anywhere). Default off.
    var clipboardOverwrite: Bool {
        get { defaults.bool(forKey: Key.clipboardOverwrite) }
        set { defaults.set(newValue, forKey: Key.clipboardOverwrite); post(SettingsStore.changed) }
    }

    // MARK: Cue sound (dictation start/stop blip)

    /// Play a Typeless-style cue sound on dictation start/stop. Default ON.
    var cueEnabled: Bool {
        get { defaults.bool(forKey: Key.cueEnabled) }
        set { defaults.set(newValue, forKey: Key.cueEnabled); post(SettingsStore.changed) }
    }

    /// Cue timbre: "tick" | "chime" | "soft" | "drop" | "marimba".
    var cueTheme: String {
        get { defaults.string(forKey: Key.cueTheme) ?? "chime" }
        set { defaults.set(newValue, forKey: Key.cueTheme); post(SettingsStore.changed) }
    }

    /// Cue volume preset: "low" (default) | "med" | "high".
    var cueVolume: String {
        get { defaults.string(forKey: Key.cueVolume) ?? "low" }
        set { defaults.set(newValue, forKey: Key.cueVolume); post(SettingsStore.changed) }
    }

    // MARK: Hotwords (contextual biasing)

    /// Master switch for hotword biasing. Toggling rebuilds the engine.
    var hotwordsEnabled: Bool {
        get { defaults.bool(forKey: Key.hotwordsEnabled) }
        set { defaults.set(newValue, forKey: Key.hotwordsEnabled); post(SettingsStore.engineConfigChanged) }
    }

    /// Raw hotword list (newline-separated). Persisted only; changes take effect
    /// via `commitHotwords()` so editing keystrokes don't thrash the engine.
    var hotwordsText: String {
        get { defaults.string(forKey: Key.hotwordsText) ?? "" }
        set { defaults.set(newValue, forKey: Key.hotwordsText) }
    }

    /// Boost strength (1.5 low / 2.0 mid / 3.0 high). Persisted only; applies via
    /// `commitHotwords()`.
    var hotwordsScore: Double {
        get {
            let v = defaults.double(forKey: Key.hotwordsScore)
            return v > 0 ? v : 5.0
        }
        set { defaults.set(newValue, forKey: Key.hotwordsScore) }
    }

    /// Commit the current hotword text + score and rebuild the engine so the new
    /// list takes effect. Call after editing the list ("Save & apply").
    func commitHotwords() { post(SettingsStore.engineConfigChanged) }

    /// Homophone correction (pinyin): rewrite same-sounding chars into the
    /// dictionary word's spelling. Default ON. No engine rebuild needed.
    var pinyinFuzzyEnabled: Bool {
        get { defaults.bool(forKey: Key.pinyinFuzzyEnabled) }
        set { defaults.set(newValue, forKey: Key.pinyinFuzzyEnabled); post(SettingsStore.changed) }
    }

    /// Inverse Text Normalization (numbers / dates / percent → 123 / 2024年 / 25%)
    /// applied to FINAL text. Default ON. Pure post-processing, no engine rebuild.
    var itnEnabled: Bool {
        get { defaults.bool(forKey: Key.itnEnabled) }
        set { defaults.set(newValue, forKey: Key.itnEnabled); post(SettingsStore.changed) }
    }

    /// Remove filler words (嗯/呃/那个那个/repeats) from FINAL text. Default ON.
    var defillerEnabled: Bool {
        get { defaults.bool(forKey: Key.defillerEnabled) }
        set { defaults.set(newValue, forKey: Key.defillerEnabled); post(SettingsStore.changed) }
    }

    /// AI 润色(Beta):大模型整理 FINAL 文本(去口癖 + 改口纠正)。默认 OFF。
    /// 纯后处理,无引擎重建。模型在线按需下载(见 ModelDownloader);未下载 / 未就绪 /
    /// 超时 / 护栏不过时,`Refiner.polish` 安全回退原文,故开关本身永不致丢字或卡顿。
    var refinerEnabled: Bool {
        get { defaults.bool(forKey: Key.refinerEnabled) }
        set { defaults.set(newValue, forKey: Key.refinerEnabled); post(SettingsStore.changed) }
    }

    // MARK: 云端大模型(Cloud LLM)

    var cloudEnabled: Bool {
        get { defaults.bool(forKey: Key.cloudEnabled) }
        set { defaults.set(newValue, forKey: Key.cloudEnabled); post(SettingsStore.changed) }
    }
    var cloudProvider: String {
        get { defaults.string(forKey: Key.cloudProvider) ?? "openai" }
        set { defaults.set(newValue, forKey: Key.cloudProvider); post(SettingsStore.changed) }
    }
    var cloudBaseURL: String {
        get { defaults.string(forKey: Key.cloudBaseURL) ?? "" }
        set { defaults.set(newValue, forKey: Key.cloudBaseURL); post(SettingsStore.changed) }
    }
    var cloudModel: String {
        get { defaults.string(forKey: Key.cloudModel) ?? "" }
        set { defaults.set(newValue, forKey: Key.cloudModel); post(SettingsStore.changed) }
    }
    var cloudModNumbers: Bool { get { defaults.bool(forKey: Key.cloudModNumbers) } set { defaults.set(newValue, forKey: Key.cloudModNumbers); post(SettingsStore.changed) } }
    var cloudModFillers: Bool { get { defaults.bool(forKey: Key.cloudModFillers) } set { defaults.set(newValue, forKey: Key.cloudModFillers); post(SettingsStore.changed) } }
    var cloudModRestate: Bool { get { defaults.bool(forKey: Key.cloudModRestate) } set { defaults.set(newValue, forKey: Key.cloudModRestate); post(SettingsStore.changed) } }
    var cloudModHotwords: Bool { get { defaults.bool(forKey: Key.cloudModHotwords) } set { defaults.set(newValue, forKey: Key.cloudModHotwords); post(SettingsStore.changed) } }
    /// 4 个处理项聚合,给 buildAutoPrompt。
    var cloudMods: RefineMods {
        RefineMods(numbers: cloudModNumbers, fillers: cloudModFillers, restate: cloudModRestate, hotwords: cloudModHotwords)
    }
    var cloudTemplatesJSON: String {
        get { defaults.string(forKey: Key.cloudTemplatesJSON) ?? "" }
        set { defaults.set(newValue, forKey: Key.cloudTemplatesJSON) }
    }
    var cloudActiveTemplate: String {
        get { defaults.string(forKey: Key.cloudActiveTemplate) ?? "auto" }
        set { defaults.set(newValue, forKey: Key.cloudActiveTemplate); post(SettingsStore.changed) }
    }
    var cloudAutoOverride: String {
        get { defaults.string(forKey: Key.cloudAutoOverride) ?? "" }
        set { defaults.set(newValue, forKey: Key.cloudAutoOverride); post(SettingsStore.changed) }
    }
    /// 自定义服务商列表(JSON: [{id,label,baseURL}])。仅持久,不实时 post。
    var cloudCustomProvidersJSON: String {
        get { defaults.string(forKey: Key.cloudCustomProvidersJSON) ?? "" }
        set { defaults.set(newValue, forKey: Key.cloudCustomProvidersJSON) }
    }
    /// 采样温度(0~1)。润色默认 0.3(稳)。未设过 → 0.3。
    var cloudTemperature: Double {
        get { defaults.object(forKey: Key.cloudTemperature) == nil ? 0.3 : defaults.double(forKey: Key.cloudTemperature) }
        set { defaults.set(newValue, forKey: Key.cloudTemperature); post(SettingsStore.changed) }
    }
    /// 最大输出 token。默认 2048。
    var cloudMaxTokens: Int {
        get { let v = defaults.integer(forKey: Key.cloudMaxTokens); return v > 0 ? v : 2048 }
        set { defaults.set(newValue, forKey: Key.cloudMaxTokens); post(SettingsStore.changed) }
    }
    /// 是否记录「最近请求」(排查用)。默认开;未设过 → true。
    var cloudLogEnabled: Bool {
        get { defaults.object(forKey: Key.cloudLogEnabled) == nil ? true : defaults.bool(forKey: Key.cloudLogEnabled) }
        set { defaults.set(newValue, forKey: Key.cloudLogEnabled); post(SettingsStore.changed) }
    }
    /// API Key — 加密存 Keychain,不进 UserDefaults。
    var cloudApiKey: String {
        get { KeychainStore.get("cloudApiKey") ?? "" }
        set { KeychainStore.set(newValue, for: "cloudApiKey"); post(SettingsStore.changed) }
    }
    /// 已保存的命名配置([CloudProfile] JSON)。含各配置的 Key → 同样存 Keychain。
    var cloudProfilesJSON: String {
        get { KeychainStore.get("cloudProfiles") ?? "" }
        set { KeychainStore.set(newValue, for: "cloudProfiles") }
    }
    /// 提交云端编辑(模板文本等只持久、不实时 post 的字段),触发引擎刷新。
    func commitCloud() { post(SettingsStore.changed) }

    // MARK: Voice snippets (trigger phrase → multi-line expansion)

    /// Master switch for snippet expansion. Default ON (empty list = no-op).
    var snippetsEnabled: Bool {
        get { defaults.bool(forKey: Key.snippetsEnabled) }
        set { defaults.set(newValue, forKey: Key.snippetsEnabled); post(SettingsStore.changed) }
    }
    /// Snippets as JSON: [{"t":"trigger","x":"expansion (may be multi-line)"}].
    /// Persisted only; applied live via `commitSnippets()`.
    var snippetsJSON: String {
        get { defaults.string(forKey: Key.snippetsJSON) ?? "[]" }
        set { defaults.set(newValue, forKey: Key.snippetsJSON) }
    }
    /// Commit edited snippets and refresh the live cache (no engine rebuild).
    func commitSnippets() { post(SettingsStore.changed) }

    /// Preferred microphone input device UID ("" = system default). Takes effect
    /// the next time recording starts.
    var inputDeviceUID: String {
        get { defaults.string(forKey: Key.inputDeviceUID) ?? "" }
        set { defaults.set(newValue, forKey: Key.inputDeviceUID); post(SettingsStore.changed) }
    }

    // MARK: Replacements (post-recognition corrections)

    /// Master switch for `from => to` text corrections. No engine rebuild needed.
    var replacementsEnabled: Bool {
        get { defaults.bool(forKey: Key.replacementsEnabled) }
        set { defaults.set(newValue, forKey: Key.replacementsEnabled); post(SettingsStore.changed) }
    }
    /// Raw rules (newline-separated "from => to"). Persisted only; applied via
    /// `commitReplacements()`.
    var replacementsText: String {
        get { defaults.string(forKey: Key.replacementsText) ?? "" }
        set { defaults.set(newValue, forKey: Key.replacementsText) }
    }
    /// Persist the edited rules and notify (applied live on the next utterance — no
    /// engine rebuild, since this is pure post-processing).
    func commitReplacements() { post(SettingsStore.changed) }

    // MARK: Launch at login

    var launchAtLogin: Bool {
        get { defaults.bool(forKey: Key.launchAtLogin) }
        set {
            defaults.set(newValue, forKey: Key.launchAtLogin)
            post(SettingsStore.launchAtLoginChanged)
        }
    }

    // MARK: Local share API (共享 — local HTTP server for coding agents)

    /// Master switch for the embedded local HTTP API. Default OFF.
    var apiEnabled: Bool {
        get { defaults.bool(forKey: Key.apiEnabled) }
        set { defaults.set(newValue, forKey: Key.apiEnabled); post(SettingsStore.apiConfigChanged) }
    }
    /// Allow LAN (0.0.0.0) access. Default OFF → bound to 127.0.0.1 only.
    var apiAllowLAN: Bool {
        get { defaults.bool(forKey: Key.apiAllowLAN) }
        set { defaults.set(newValue, forKey: Key.apiAllowLAN); post(SettingsStore.apiConfigChanged) }
    }
    /// TCP port for the local API (default 8765).
    var apiPort: Int {
        get { let v = defaults.integer(forKey: Key.apiPort); return v > 0 ? v : 8473 }
        set { defaults.set(newValue, forKey: Key.apiPort); post(SettingsStore.apiConfigChanged) }
    }
    /// Bearer key required on every request. Generated + persisted on first access; never empty.
    var apiKey: String {
        if let k = defaults.string(forKey: Key.apiKey), !k.isEmpty { return k }
        let k = Self.generateKey()
        defaults.set(k, forKey: Key.apiKey)
        return k
    }
    /// Rotate the key (invalidates any skill already shared with the old key).
    @discardableResult func regenerateAPIKey() -> String {
        let k = Self.generateKey()
        defaults.set(k, forKey: Key.apiKey)
        post(SettingsStore.apiConfigChanged)
        return k
    }
    private static func generateKey() -> String {
        let chars = Array("abcdefghijkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        return "vibe_" + String((0..<28).map { _ in chars.randomElement()! })
    }

    // MARK: -

    private func post(_ name: Notification.Name) {
        NotificationCenter.default.post(name: name, object: self)
        NotificationCenter.default.post(name: SettingsStore.changed, object: self)
    }
}
