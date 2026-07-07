import AppKit
import AVFoundation
import SwiftUI
import VibeUI
import Sparkle
import os

/// Vibe XASR — menu-bar (LSUIElement-capable) push-to-talk dictation app.
///
/// Wiring:
///   * NSStatusItem (🎙 / ⏳ loading / 🔴 listening / ✍️ working) + menu.
///   * DictationEngine(vad: <FireRed|Silero>, asr: SherpaASR(tier), prerollSec: 1.0)
///     loaded on a background queue (~3 s); logs "engine ready" to stderr when done.
///   * Transparent non-activating always-on-top HUD NSPanel hosting HUDView.
///   * Hotkey (right-⌘) push-to-talk: hold → listen + stream partials; release →
///     finalize + paste/type the joined sentences (+ optional Pad/History append).
///   * Live engine swap when the VAD kind or latency tier changes (off the audio
///     path, on the main actor), with a brief "切换中…" state in Settings.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {

    // MARK: UI
    private var statusItem: NSStatusItem!
    private let hudModel = HUDModel()
    /// Separate model driven ONLY by the in-window onboarding "try it" session,
    /// so the floating HUD panel (bound to `hudModel`) never shows during a try.
    private let tryHUD = HUDModel()
    private var hudPanel: NSPanel!
    // AI 润色异步等待 → HUD「润色中」+「立即插入」。一段释放后润色未返回时持有规则版兜底。
    private var pendingPolishRaw: String?
    private var pendingPolishRule: String?
    private var polishTask: Task<Void, Never>?
    private var slowWork: DispatchWorkItem?
    private var finalizeFallbackWork: DispatchWorkItem?   // 空点一下的兜底收尾
    /// 本次润色前,本地规则(同音字/替换)所做改动的描述,注入 {{changes}} 供大模型复核。
    private var currentRuleChanges = "(无)"
    /// 本次听写要套用的模板(模板快捷键触发时设;主快捷键为 nil → 用当前选中模板/自动)。
    private var currentSessionTemplateId: String?
    /// 是否有就绪的润色后端(云端或本地)。判定走异步润色路径,而非看本地开关(云端开关是 cloudEnabled)。
    private var refinerActive: Bool { Refiner.shared.backend?.isReady == true }
    private let cloudLongFormThreshold = 100
    /// 单击切换模式下,当前是否正在听写(用于把第二次按键解读为「停止」)。
    private var toggleDictating = false
    /// 智能模式(按住说话 / 轻点锁定)的运行状态。
    private var hybridPressAt: Date?       // 本次按下时刻;判定轻点(短按)还是长按
    private var hybridLatched = false      // 轻点已锁定(免持,等下一次轻点停止)
    private var hybridIgnoreUp = false     // 「再点停止」那一下的松开要忽略
    private let tapThreshold: TimeInterval = 0.35   // ≤ 此值算「轻点」→ 锁定;否则算「长按」→ 松开即停
    /// 临时静音麦克风(菜单栏快捷开关);开启时 beginDictation 直接 no-op。运行时态,不持久化。
    private var micMuted = false
    /// 落字后「撤销 / 重润色」用:本次原始 ASR + 实际插入的文本(仅 paste 模式 + 润色过)。
    private var lastRawASR: String?
    private var lastInserted: String?
    private var settingsWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    private var padWindow: NSWindow?
    private var historyWindow: NSWindow?
    private var promptStudioWindow: NSWindow?
    private var statusMenuItem: NSMenuItem!
    private var dockToggleItem: NSMenuItem!
    private var aiPolishItem: NSMenuItem!       // 快捷:AI 润色 开/关(暂停)
    private var templateItem: NSMenuItem!       // 快捷:当前生效模板(子菜单)
    private var micMuteItem: NSMenuItem!        // 快捷:临时静音麦克风
    // Held so the menu can be re-localized live when the UI language changes.
    private var settingsItem: NSMenuItem!
    private var padItem: NSMenuItem!
    private var historyItem: NSMenuItem!
    private var rerunItem: NSMenuItem!
    private var updateItem: NSMenuItem!
    private var quitItem: NSMenuItem!

    // MARK: Auto-update (Sparkle)
    /// Drives the appcast check / download / verify / install. `startingUpdater: true`
    /// kicks off the scheduled background checks per Info.plist (SUEnableAutomaticChecks).
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

    // MARK: Settings (single source of truth)
    private let store = SettingsStore.shared
    private let history = HistoryStore.shared
    /// Held for the app's lifetime so the global push-to-talk hotkey keeps firing
    /// with no window open: without it, App Nap / automatic termination suspends the
    /// windowless background app and the CGEventTap goes silent.
    private var bgActivity: NSObjectProtocol?
    private let pad = PadStore.shared
    /// Parsed post-recognition correction rules (refreshed on settings change).
    private var replacementRules: [Replacements.Rule] = []
    /// Parsed snippet expansions (trigger → text), reusing the replacement engine.
    private var snippetRules: [Replacements.Rule] = []
    private let downloader = ModelDownloader.shared

    // MARK: Engine
    private var engine: DictationEngine?
    private let mic = Mic()
    private var hotkey: Hotkey                 // recreated when the keycode changes
    private var engineReady = false
    /// True while a VAD/tier swap is rebuilding the engine (Settings shows 切换中…).
    private(set) var engineSwapping = false

    override init() {
        let s = SettingsStore.shared
        // 仅默认主键;模板快捷键在 applicationDidFinishLaunching 的 rebuildHotkeys() 里补上。
        self.hotkey = Hotkey(bindings: [Hotkey.Binding(id: nil, keycode: CGKeyCode(s.hotkeyKeyCode),
                                                       mods: HotkeyMods(rawValue: s.hotkeyMods),
                                                       modifierOnly: s.hotkeyModifierOnly)])
        super.init()
    }

    // MARK: Dictation pass state
    /// Robust streaming inserter — one-char Unicode keystrokes on a serial queue
    /// (replaces the old chunked typeOut that dropped characters).
    private let inserter = StreamingInserter()
    private var elapsedTimer: Timer?
    private var sessionStart: Date?
    private var hideWorkItem: DispatchWorkItem?

    // MARK: Unified live insertion session

    private struct SessionChunk {
        let id: UUID
        let raw: String
        var display: String
        var polishing: Bool
        var sealed: Bool
    }

    private enum SessionSink {
        case focusedInsert
        case clipboardOnly
    }

    private var sessionChunks: [SessionChunk] = []
    private var sessionPartial = ""
    private var sessionSink: SessionSink = .focusedInsert
    private var sessionStopped = false
    private var sessionGeneration = 0
    private var sessionHistoryID: UUID?
    private var sessionLastClipboard = ""
    private var sessionWindowPolishTask: Task<Void, Never>?
    private var sessionWindowPolishToken = 0
    private var sessionLongFormTask: Task<Void, Never>?
    private var sessionLongFormMode = false
    private var sessionRawLog: [String] = []
    private var sessionFlushedRawChars = 0
    private var sessionTailRaw = ""
    private var sessionPendingSealCandidate: String?
    private var sessionPendingSealSince: Date?

    // MARK: Onboarding "try it" state
    private var inTry = false
    private var onboardingActive = false

    // ============================================================
    // App lifecycle
    // ============================================================

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hook VibeUI's runtime localization to the persisted choice.
        L10n.shared.persistence = store

        NSApp.setActivationPolicy(store.showDockIcon ? .regular : .accessory)
        setupStatusItem()
        setupHUDPanel()
        loadEngine()
        wireMic()
        rebuildHotkeys()          // 主键 + 模板快捷键(组合),并 start
        keepAliveInBackground()   // keep the global hotkey responsive with no window open

        installEditMenu()      // so ⌘C/⌘V/⌘X/⌘A/⌘Z work in Settings text fields
        observeSettings()
        restartAPIServer()     // start the local share API if it was left enabled
        CueSound.shared.gain = CueSound.gain(for: store.cueVolume)   // sync cue volume
        PinyinNormalizer.shared.loadTableIfNeeded(path: ModelPaths.pinyinTablePath())
        refreshCorrections()   // load replacement rules + pinyin dictionary words
        applyLaunchAtLogin()   // reconcile the login item with the stored pref

        if !store.didCompleteOnboarding {
            openOnboarding()
        }
    }

    /// macOS routes ⌘X/⌘C/⌘V/⌘A/⌘Z to the focused text field via the main menu's
    /// Edit items' key equivalents. As a menu-bar (accessory) app we have no main
    /// menu by default, so text fields in Settings couldn't copy/paste/select-all.
    /// Install a minimal main menu with a standard Edit menu (works even while the
    /// menu bar itself isn't shown in accessory mode).
    private func installEditMenu() {
        let main = NSMenu()

        // App menu placeholder (first item is conventionally the app menu).
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(withTitle: L10n.shared.t("menu.quit"),
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        // Edit menu — the one that makes the clipboard shortcuts work.
        let editItem = NSMenuItem()
        main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        editItem.submenu = edit
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: Selector(("cut:")), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: Selector(("copy:")), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: Selector(("paste:")), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: Selector(("selectAll:")), keyEquivalent: "a")

        NSApp.mainMenu = main
    }

    /// React to store mutations posted from Settings / onboarding / menu.
    private func observeSettings() {
        let nc = NotificationCenter.default
        nc.addObserver(forName: SettingsStore.hotkeyChanged, object: nil, queue: .main) {
            [weak self] _ in
            MainActor.assumeIsolated { self?.rebuildHotkeys() }
        }
        // 设置页「在新窗口打开」提示词工作室(VibeUI 经通知解耦)。
        nc.addObserver(forName: .vibeOpenPromptStudio, object: nil, queue: .main) {
            [weak self] _ in
            MainActor.assumeIsolated { self?.openPromptStudio() }
        }
        nc.addObserver(forName: SettingsStore.dockIconChanged, object: nil, queue: .main) {
            [weak self] _ in
            MainActor.assumeIsolated { self?.applyDockPolicy() }
        }
        nc.addObserver(forName: SettingsStore.engineConfigChanged, object: nil, queue: .main) {
            [weak self] _ in
            MainActor.assumeIsolated { self?.rebuildEngineForConfig() }
        }
        nc.addObserver(forName: SettingsStore.launchAtLoginChanged, object: nil, queue: .main) {
            [weak self] _ in
            MainActor.assumeIsolated { self?.applyLaunchAtLogin() }
        }
        nc.addObserver(forName: SettingsStore.apiConfigChanged, object: nil, queue: .main) {
            [weak self] _ in
            MainActor.assumeIsolated { self?.restartAPIServer() }
        }
        // When a download finishes, if the just-completed tier is the one the
        // user selected, swap the engine onto it.
        nc.addObserver(forName: SettingsStore.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshCorrections(); self?.relocalizeChrome() }
        }
    }

    /// 语言切换后,刷新「命令式」AppKit 文案:状态栏菜单标题 + 各窗口标题。
    /// (SwiftUI 内容自己 observe L10n 会变;NSMenu / NSWindow.title 是一次性设的,需手动重设。)
    private func relocalizeChrome() {
        relocalizeMenu()
        settingsWindow?.title = L10n.shared.t("settings.window.title")
        historyWindow?.title = L10n.shared.t("history.title")
        padWindow?.title = L10n.shared.t("pad.title")
        promptStudioWindow?.title = L10n.shared.t("studio.window.title")
    }

    /// Apply the current Dock-icon preference live + keep the menu toggle synced.
    private func applyDockPolicy() {
        NSApp.setActivationPolicy(store.showDockIcon ? .regular : .accessory)
        dockToggleItem?.state = store.showDockIcon ? .on : .off
        if store.showDockIcon,
           settingsWindow != nil || onboardingWindow != nil
            || padWindow != nil || historyWindow != nil {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// 拆掉旧 tap,按当前设置(主键 + 模板快捷键)重建并启动。主键/模板键变更时调用。
    private func rebuildHotkeys() {
        hotkey.stop()
        toggleDictating = false   // 重建(含模式切换)时清掉切换态,避免卡在「已开始」
        hybridLatched = false; hybridPressAt = nil; hybridIgnoreUp = false
        hotkey = Hotkey(bindings: makeHotkeyBindings())
        wireHotkeys()
        _ = hotkey.start()
    }
    /// 组装绑定:默认主键 + 每个仍存在的模板的快捷键(去掉孤儿、去重)。
    private func makeHotkeyBindings() -> [Hotkey.Binding] {
        var out: [Hotkey.Binding] = [
            Hotkey.Binding(id: nil, keycode: CGKeyCode(store.hotkeyKeyCode),
                           mods: HotkeyMods(rawValue: store.hotkeyMods), modifierOnly: store.hotkeyModifierOnly)
        ]
        let ids = AppDelegate.decodeTemplateIds(store.cloudTemplatesJSON)
        for (tid, h) in CloudTemplateHotkeys.decode(store.cloudTemplateHotkeysJSON) {
            guard ids.contains(tid) else { continue }   // 模板已删 → 跳过
            let b = Hotkey.Binding(id: tid, keycode: CGKeyCode(h.keyCode),
                                   mods: HotkeyMods(rawValue: h.mods), modifierOnly: h.modifierOnly)
            // 与已有绑定撞键 → 跳过(主键优先,先到先得)。
            if out.contains(where: { $0.keycode == b.keycode && $0.mods == b.mods && $0.modifierOnly == b.modifierOnly }) { continue }
            out.append(b)
        }
        return out
    }
    static func decodeTemplateIds(_ json: String) -> Set<String> {
        guard let d = json.data(using: .utf8),
              let a = try? JSONDecoder().decode([PromptTemplate].self, from: d) else { return [] }
        return Set(a.map { $0.id })
    }

    /// (Re)start or stop the local share API (共享) to match current settings.
    private func restartAPIServer() {
        LocalAPIServer.shared.restart(port: UInt16(clamping: store.apiPort),
                                      allowLAN: store.apiAllowLAN,
                                      enabled: store.apiEnabled)
    }

    /// Opt out of App Nap + automatic/sudden termination so the global push-to-talk
    /// hotkey (a CGEventTap on the main run loop) keeps firing while the app sits in
    /// the background with no window. Idle system sleep is still allowed.
    private func keepAliveInBackground() {
        guard bgActivity == nil else { return }
        bgActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep, .automaticTerminationDisabled, .suddenTerminationDisabled],
            reason: "Global push-to-talk dictation must stay responsive in the background")
    }

    /// Primary LAN IPv4 (en*) — shown so a reachable URL exists when LAN access is on.
    static func primaryLANIPv4() -> String? {
        var result: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return nil }
        defer { freeifaddrs(ifaddr) }
        var ptr = ifaddr
        while let p = ptr {
            let f = Int32(p.pointee.ifa_flags)
            if (f & (IFF_UP | IFF_RUNNING)) == (IFF_UP | IFF_RUNNING),
               (f & IFF_LOOPBACK) == 0,
               let sa = p.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET),
               String(cString: p.pointee.ifa_name).hasPrefix("en") {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count),
                               nil, 0, NI_NUMERICHOST) == 0 {
                    result = String(cString: host); break
                }
            }
            ptr = p.pointee.ifa_next
        }
        return result
    }

    /// Clicking the Dock icon with no window open → show Settings.
    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            if onboardingWindow != nil {
                onboardingWindow?.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            } else {
                openSettings()
            }
        }
        return true
    }

    /// 退出时直接干净结束进程,跳过 C++ atexit 静态析构 —— llama.cpp 的 ggml-metal 在退出
    /// 析构时有竞争会 abort(后台 Metal 初始化线程未完成)。设置/历史均实时落盘,无需退出清理;
    /// OS 会回收一切。这样退出不再崩溃、不弹报告(仅 AI 润色开启、加载了 Metal 时才会触发)。
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        _exit(0)
    }

    // ============================================================
    // Status bar + menu
    // ============================================================

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        setStatusIcon("⏳")

        let menu = NSMenu()
        statusMenuItem = NSMenuItem(title: L10n.shared.t("menu.loading"), action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)
        menu.addItem(.separator())

        // ===== 快捷开关(即点即生效)=====
        aiPolishItem = NSMenuItem(title: L10n.shared.t("menu.aiPolish"),
                                  action: #selector(toggleAIPolish), keyEquivalent: "")
        aiPolishItem.target = self
        menu.addItem(aiPolishItem)

        templateItem = NSMenuItem(title: L10n.shared.t("menu.template"), action: nil, keyEquivalent: "")
        templateItem.submenu = NSMenu()
        menu.addItem(templateItem)

        micMuteItem = NSMenuItem(title: L10n.shared.t("menu.micMute"),
                                 action: #selector(toggleMicMute), keyEquivalent: "")
        micMuteItem.target = self
        menu.addItem(micMuteItem)
        menu.addItem(.separator())

        dockToggleItem = NSMenuItem(title: L10n.shared.t("menu.showDock"),
                                    action: #selector(toggleDockIcon), keyEquivalent: "")
        dockToggleItem.target = self
        dockToggleItem.state = store.showDockIcon ? .on : .off
        menu.addItem(dockToggleItem)
        menu.addItem(.separator())

        settingsItem = NSMenuItem(title: L10n.shared.t("menu.settings"),
                                  action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        // NEW: Pad + History entries (alongside Settings…).
        padItem = NSMenuItem(title: L10n.shared.t("menu.pad"),
                             action: #selector(openPad), keyEquivalent: "")
        padItem.target = self
        menu.addItem(padItem)

        historyItem = NSMenuItem(title: L10n.shared.t("menu.history"),
                                 action: #selector(openHistory), keyEquivalent: "")
        historyItem.target = self
        menu.addItem(historyItem)

        rerunItem = NSMenuItem(title: L10n.shared.t("menu.rerun"),
                               action: #selector(rerunOnboarding), keyEquivalent: "")
        rerunItem.target = self
        menu.addItem(rerunItem)

        updateItem = NSMenuItem(title: L10n.shared.t("about.checkUpdate"),
                                action: #selector(checkForUpdatesMenu), keyEquivalent: "")
        updateItem.target = self
        menu.addItem(updateItem)

        menu.addItem(.separator())

        quitItem = NSMenuItem(title: L10n.shared.t("menu.quit"), action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        menu.delegate = self   // 打开前刷新动态状态(勾选 / 模板子菜单)
        statusItem.menu = menu
    }

    /// 重建「当前生效模板」子菜单:⚡自动 + 内置「口语转书面」+ 自定义模板,勾选当前项。
    private func rebuildTemplateSubmenu() {
        guard let submenu = templateItem?.submenu else { return }
        submenu.removeAllItems()
        let active = store.cloudActiveTemplate
        func add(_ id: String, _ name: String) {
            let it = NSMenuItem(title: name, action: #selector(setActiveTemplate(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = id
            it.state = (active == id) ? .on : .off
            submenu.addItem(it)
        }
        add("auto", L10n.shared.t("llm.tpl.auto"))
        let lang = L10n.resolve(stored: store.storedLang)
        for t in AppDelegate.decodeTemplates(store.cloudTemplatesJSON) {
            // 内置锁定 t1 随 UI 语言显示名;自定义模板用其存储名。
            let name = (t.id == LocalizedPrompts.seedTemplateId) ? LocalizedPrompts.seed(lang: lang).name : t.name
            add(t.id, name)
        }
    }
    static func decodeTemplates(_ json: String) -> [PromptTemplate] {
        guard let d = json.data(using: .utf8),
              let a = try? JSONDecoder().decode([PromptTemplate].self, from: d) else { return [] }
        return a
    }

    @objc private func toggleAIPolish() {
        store.polishPaused.toggle()
        refreshRefiner()
        aiPolishItem?.state = polishRuntimeEnabled() ? .on : .off
    }
    @objc private func setActiveTemplate(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        store.cloudActiveTemplate = id
        rebuildTemplateSubmenu()
    }
    @objc private func toggleMicMute() {
        micMuted.toggle()
        if micMuted, toggleDictating { endDictation() }   // 静音时若正在听写,立即收掉
        micMuteItem?.state = micMuted ? .on : .off
    }

    /// Re-apply localized titles to the native menu when the UI language changes
    /// (the AppKit NSMenu isn't a SwiftUI view, so it can't observe L10n itself).
    private func relocalizeMenu() {
        aiPolishItem?.title = L10n.shared.t("menu.aiPolish")
        templateItem?.title = L10n.shared.t("menu.template")
        micMuteItem?.title = L10n.shared.t("menu.micMute")
        dockToggleItem?.title = L10n.shared.t("menu.showDock")
        settingsItem?.title = L10n.shared.t("menu.settings")
        padItem?.title = L10n.shared.t("menu.pad")
        historyItem?.title = L10n.shared.t("menu.history")
        rerunItem?.title = L10n.shared.t("menu.rerun")
        updateItem?.title = L10n.shared.t("about.checkUpdate")
        quitItem?.title = L10n.shared.t("menu.quit")
        // Refresh the dynamic status line if the engine is already up.
        if engineReady { statusMenuItem?.title = L10n.shared.t("menu.ready") }
        else if !engineSwapping { statusMenuItem?.title = L10n.shared.t("menu.loading") }
    }

    @objc private func toggleDockIcon() {
        store.showDockIcon.toggle()   // posts dockIconChanged → applyDockPolicy()
    }

    /// 菜单打开前刷新动态状态:AI 润色 / 静音勾选 + 重建模板子菜单(勾当前项)。
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === statusItem.menu else { return }   // 只刷顶层(子菜单单独重建)
        aiPolishItem?.state = polishRuntimeEnabled() ? .on : .off
        micMuteItem?.state = micMuted ? .on : .off
        rebuildTemplateSubmenu()
    }

    /// Set the menu-bar glyph. Callers still pass the legacy emoji string for the
    /// state; we map it to a crisp SF Symbol template image (emoji-as-title render
    /// as tofu boxes on some menu bars). Template images auto-adapt to light/dark;
    /// a non-nil tint colors active states (red = recording, green = OnCall).
    private func setStatusIcon(_ icon: String) {
        guard let button = statusItem.button else { return }
        let tint: NSColor?
        switch icon {
        case "🔴": tint = .systemRed       // recording
        case "📞": tint = .systemGreen     // OnCall live
        case "⚠️": tint = .systemOrange    // error
        case "⏸": tint = .systemGray      // OnCall paused
        default:  tint = nil               // ready / loading / finalizing → template (auto b/w)
        }
        let img = AppDelegate.drawnBarsIcon(tint: tint)
        button.image = img
        button.imageScaling = .scaleProportionallyDown
        button.imagePosition = .imageOnly   // never render the title → no tofu/□ glyph
        button.attributedTitle = NSAttributedString(string: "")
        button.title = ""
        button.contentTintColor = nil       // colors are baked into the drawn image
    }

    /// Draw the Vibe "three bars" mark as a menu-bar icon. Done by hand (Core
    /// Graphics) instead of an SF Symbol so it ALWAYS renders — some menu bars
    /// were showing a tofu/□ box for symbol/emoji glyphs. `tint == nil` returns a
    /// template image (auto black/white); a color bakes that color in (active states).
    static func drawnBarsIcon(tint: NSColor?) -> NSImage {
        let size = NSSize(width: 18, height: 16)
        let img = NSImage(size: size, flipped: false) { rect in
            (tint ?? NSColor.black).setFill()
            let barW: CGFloat = 2.6, gap: CGFloat = 2.4
            let heights: [CGFloat] = [7, 13, 9]
            let total = barW * 3 + gap * 2
            var x = (rect.width - total) / 2
            let midY = rect.height / 2
            for h in heights {
                let r = NSRect(x: x, y: midY - h / 2, width: barW, height: h)
                NSBezierPath(roundedRect: r, xRadius: 1.2, yRadius: 1.2).fill()
                x += barW + gap
            }
            return true
        }
        img.isTemplate = (tint == nil)
        return img
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    /// Status-menu "检查更新" → Sparkle user-initiated check.
    @objc private func checkForUpdatesMenu() {
        checkForUpdates()
    }

    @objc private func openSettings() {
        if let w = settingsWindow {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        // Pass `self` as the SettingsBridge + the observable ModelDownloader so
        // the Model tab shows live download progress and the engine swaps live.
        let hosting = NSHostingController(rootView:
            SettingsView(bridge: self, manager: downloader,
                         records: AnyView(HistoryView(store: HistoryStore.shared))))
        let window = NSWindow(contentViewController: hosting)
        window.title = L10n.shared.t("settings.window.title")
        // Plain NATIVE title bar: "偏好设置" + traffic lights on ONE row. The earlier
        // transparent-titlebar + fullSizeContentView + custom strip approach rendered
        // as two rows; this avoids it entirely.
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        // Wide enough for the redesigned 记录 workspace (sidebar + content + calendar rail).
        window.setContentSize(NSSize(width: 1080, height: 680))
        window.contentMinSize = NSSize(width: 720, height: 520)
        window.isReleasedWhenClosed = false
        window.center()
        window.delegate = self
        settingsWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // ============================================================
    // Pad + History windows (NEW)
    // ============================================================

    @objc private func openPad() {
        if let w = padWindow {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let hosting = NSHostingController(rootView: PadView(store: pad))
        let window = NSWindow(contentViewController: hosting)
        window.title = L10n.shared.t("pad.title")
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 520, height: 460))
        window.isReleasedWhenClosed = false
        window.center()
        window.delegate = self
        padWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func openHistory() {
        if let w = historyWindow {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let hosting = NSHostingController(rootView: HistoryView(store: history))
        let window = NSWindow(contentViewController: hosting)
        window.title = L10n.shared.t("history.title")
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 1080, height: 760))
        window.contentMinSize = NSSize(width: 720, height: 460)
        window.isReleasedWhenClosed = false
        window.center()
        window.delegate = self
        historyWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 在独立窗口打开「提示词模板工作室」(与设置页共用同一份模板数据,经同一 bridge → SettingsStore)。
    @objc private func openPromptStudio() {
        if let w = promptStudioWindow {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let hosting = NSHostingController(rootView: PromptStudioWindowView(bridge: self))
        let window = NSWindow(contentViewController: hosting)
        window.title = L10n.shared.t("studio.window.title")
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 720, height: 600))
        window.contentMinSize = NSSize(width: 520, height: 420)
        window.isReleasedWhenClosed = false
        window.center()
        window.delegate = self
        promptStudioWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // ============================================================
    // Onboarding wizard
    // ============================================================

    @objc private func rerunOnboarding() {
        openOnboarding()
    }

    private func openOnboarding() {
        if let w = onboardingWindow {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let hosting = NSHostingController(rootView: OnboardingView(bridge: self))
        let window = NSWindow(contentViewController: hosting)
        window.title = "Vibe XASR"
        window.styleMask = [.titled, .closable]
        window.setContentSize(NSSize(width: 560, height: 460))
        window.isReleasedWhenClosed = false
        window.center()
        window.delegate = self
        onboardingWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func closeOnboarding() {
        onboardingWindow?.close()
        onboardingWindow = nil
    }

    // ============================================================
    // HUD overlay panel
    // ============================================================

    private func setupHUDPanel() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 220, height: 64),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false

        let hosting = NSHostingView(rootView:
            HUDView(model: hudModel, form: .compact)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        )
        hosting.frame = panel.contentView!.bounds
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting

        hudPanel = panel
        positionHUD()
    }

    private func positionHUD(topRight: Bool = false) {
        guard let screen = NSScreen.main else { return }
        let vis = screen.visibleFrame
        let size = hudPanel.frame.size
        if topRight {                                  // OnCall: persistent top-right
            hudPanel.setFrameOrigin(NSPoint(x: vis.maxX - size.width - 20,
                                            y: vis.maxY - size.height - 12))
        } else {                                       // push-to-talk: bottom-center
            hudPanel.setFrameOrigin(NSPoint(x: vis.midX - size.width / 2,
                                            y: vis.minY + 120))
        }
    }

    private func showHUD() {
        hideWorkItem?.cancel()
        positionHUD()
        hudPanel.orderFrontRegardless()
    }

    private func hideHUD(after seconds: TimeInterval) {
        hideWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.hudPanel.orderOut(nil)
            self?.hudModel.reset()
        }
        hideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    /// 「已插入」结果的停留时长 = 用户设置,但有个 0.6s 渲染地板:
    /// 太短(尤其「立刻」=0)会在 SwiftUI 画出最终/润色文本前就 orderOut,导致「字没显示全就消失」。
    private func doneStaySeconds() -> TimeInterval { min(max(store.hudStaySeconds, 0.6), 1.2) }

    // ============================================================
    // Engine loading + live swap (background)
    // ============================================================

    private func loadEngine() {
        rebuildEngine(announceReady: true)
    }

    /// Build (or rebuild) the engine from the current store config — chosen VAD
    /// kind + latency tier. Runs the model load on a background queue and swaps
    /// the engine in on the main actor when ready. Safe to call repeatedly.
    private func rebuildEngine(announceReady: Bool) {
        let vadKind = store.vadKind
        let tier = store.latencyTierEnum
        // Resolve the ASR dir for the chosen tier. If it isn't available yet
        // (a non-bundled tier that hasn't finished downloading), fall back to the
        // bundled 960 ms so dictation keeps working, and kick off the download.
        let resolvedTier: String
        let asrDir: String
        if let dir = ModelPaths.asrDir(forTier: tier.token) {
            resolvedTier = tier.token
            asrDir = dir
        } else {
            resolvedTier = ModelPaths.bundledTier
            asrDir = ModelPaths.bundledAsrDir()
            downloader.startDownload(tier)   // fetch the requested tier in the background
        }
        let vadDir = ModelPaths.firedDir()
        let sileroPath = ModelPaths.sileroModelPath()

        // Hotwords (contextual biasing): persist the user's list so the recognizer
        // can load it; resolve the BPE vocab for English terms. When disabled,
        // remove the file so the engine stays on greedy_search (zero regression).
        let hwURL = ModelPaths.hotwordsFilePath()
        let mergedHotwords = combinedHotwordWords()
        if store.hotwordsEnabled {
            HotwordsStore.writeWords(mergedHotwords, score: store.hotwordsScore, to: hwURL)
        } else {
            try? FileManager.default.removeItem(at: hwURL)
        }
        let hwFile: String? = (store.hotwordsEnabled && HotwordsStore.isNonEmpty(hwURL)) ? hwURL.path : nil
        let hwScore = Float(store.hotwordsScore)
        let bpeVocab = ModelPaths.bpeVocabPath()

        FileHandle.standardError.write(
            "[VibeIME] building engine  vad=\(vadKind) tier=\(resolvedTier) asr=\(asrDir) hotwords=\(hwFile != nil) bpe=\(bpeVocab != nil)\n".data(using: .utf8)!)

        if !announceReady {
            engineSwapping = true
            statusMenuItem.title = L10n.shared.t("switching")
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // Build the chosen VAD; fall back to FireRedVAD if silero is missing.
            let vad: StreamingVAD?
            if vadKind == "silero" {
                if let s = SileroVAD(modelPath: sileroPath) {
                    vad = s
                } else {
                    FileHandle.standardError.write(
                        "[VibeIME] silero model missing → falling back to FireRedVAD\n".data(using: .utf8)!)
                    vad = FireRedVAD(modelDir: vadDir)
                }
            } else {
                vad = FireRedVAD(modelDir: vadDir)
            }
            guard let vad else {
                self?.engineFailed("VAD 模型加载失败 / VAD model failed", dir: vadDir)
                return
            }
            guard ModelPaths.tierFilesPresent(asrDir, tier: resolvedTier) else {
                self?.engineFailed("ASR 模型文件缺失 / ASR model missing", dir: asrDir)
                return
            }
            let asr = SherpaASR(asrDir: asrDir, tier: resolvedTier,
                                hotwordsFile: hwFile, hotwordsScore: hwScore,
                                bpeVocab: bpeVocab)
            let engine = DictationEngine(vad: vad, asr: asr, prerollSec: 1.0, holdToTalk: true)

            DispatchQueue.main.async {
                guard let self else { return }
                self.engine = engine
                self.engineReady = true
                self.engineSwapping = false
                self.setStatusIcon("🎙")
                self.statusMenuItem.title = L10n.shared.t("menu.ready")
                // (Re)start OnCall on this (possibly newly-swapped) engine if selected.
                if self.onCallActive { self.onCallActive = false; self.mic.stop() }
                self.applyDictationMode()
                if announceReady {
                    FileHandle.standardError.write("engine ready\n".data(using: .utf8)!)
                } else {
                    FileHandle.standardError.write("engine swapped\n".data(using: .utf8)!)
                }
            }
        }
    }

    /// Called when the VAD kind or latency tier changes. Rebuilds the engine off
    /// the audio path (only while not mid-dictation), showing a brief swap state.
    private func rebuildEngineForConfig() {
        // Don't yank the engine out from under an in-flight capture; the change
        // applies on the next rebuild. In practice the picker is in Settings, so
        // the user isn't holding the hotkey simultaneously.
        guard !inTry, hudModel.phase == .idle else {
            // Defer until idle.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.rebuildEngineForConfig()
            }
            return
        }
        rebuildEngine(announceReady: false)
    }

    nonisolated private func engineFailed(_ message: String, dir: String) {
        FileHandle.standardError.write(
            "[VibeIME] ENGINE LOAD FAILED: \(message) (\(dir))\n".data(using: .utf8)!)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.engineSwapping = false
            self.setStatusIcon("⚠️")
            self.statusMenuItem.title = message
        }
    }

    // ============================================================
    // Hotkey + mic + engine callbacks
    // ============================================================

    /// 绑定快捷键回调到当前 hotkey 实例(主键 id==nil;模板键 id==templateId → 设会话模板)。
    private func wireHotkeys() {
        hotkey.onFire = { [weak self] id, isDown in
            DispatchQueue.main.async {
                guard let self else { return }
                if self.store.hotkeyToggleMode {
                    // 纯单击切换:只在按下动作,忽略松开。第一次按→开始,第二次按→停止。
                    guard isDown else { return }
                    if self.toggleDictating { self.toggleDictating = false; self.endDictation() }
                    else { self.toggleDictating = true; self.currentSessionTemplateId = id; self.beginDictation() }
                } else {
                    // 智能模式(默认):长按=按住说话(松开即停);轻点=锁定(再轻点停止)。
                    self.handleHybrid(id: id, isDown: isDown)
                }
            }
        }
    }

    /// 智能模式分发:按下开始;松开时按「按下时长」决定——短按(轻点)锁定免持,长按则停止。
    /// 已锁定时,下一次按下即停止(忽略其后的松开)。
    private func handleHybrid(id: String?, isDown: Bool) {
        if isDown {
            if hybridLatched {                       // 锁定中再按 → 停止
                hybridLatched = false
                hybridIgnoreUp = true                // 这一下的松开要忽略
                endDictation()
            } else {                                  // 开始一段(先按住,松开时再判定轻点/长按)
                hybridPressAt = Date()
                currentSessionTemplateId = id
                beginDictation()
            }
        } else {
            if hybridIgnoreUp { hybridIgnoreUp = false; return }
            guard let downAt = hybridPressAt else { return }
            hybridPressAt = nil
            if Date().timeIntervalSince(downAt) < tapThreshold {
                hybridLatched = true                  // 轻点 → 锁定,继续听写
            } else {
                endDictation()                        // 长按 → 松开即停
            }
        }
    }

    private func wireMic() {
        mic.onSamples = { [weak self] samples in
            guard let self else { return }
            self.engine?.feed(samples)
            let level = AppDelegate.rmsLevel(samples)
            DispatchQueue.main.async {
                if self.inTry {
                    if self.tryHUD.phase != .idle { self.tryHUD.level = level }
                } else if self.hudModel.phase != .idle {
                    self.hudModel.level = level
                }
            }
        }
    }

    /// Refresh the live post-recognition correction caches (call on launch + on any
    /// settings change): the literal replacement rules AND the pinyin normalizer's
    /// dictionary words. Empty when disabled → corrected() is a no-op.
    private func refreshCorrections() {
        replacementRules = store.replacementsEnabled ? Replacements.parse(store.replacementsText) : []
        snippetRules = store.snippetsEnabled ? AppDelegate.parseSnippets(store.snippetsJSON) : []
        PinyinNormalizer.shared.setWords(store.pinyinFuzzyEnabled ? combinedHotwordWords() : [])
        refreshRefiner()
    }

    private func selectedHotwordDomains() -> [HotwordDomain] {
        store.hotwordDomainIDs.compactMap(HotwordDomainCatalog.byID)
    }

    private func combinedHotwordWords() -> [String] {
        HotwordsStore.mergedWords(
            defaults: HotwordDomainCatalog.words(for: store.hotwordDomainIDs),
            customText: store.hotwordsText
        )
    }

    private func combinedHotwordsText() -> String {
        combinedHotwordWords().joined(separator: "\n")
    }

    private func applyFinalHotwordReplacement(_ text: String) -> String {
        let words = combinedHotwordWords()
        guard !words.isEmpty else { return text }
        let cjkNormalized = PinyinNormalizer.shared.normalize(text, withRawWords: words)
        let aliases = HotwordDomainCatalog.aliasMap(for: store.hotwordDomainIDs)
        return HotwordCanonicalizer.rewrite(cjkNormalized, canonicalWords: words, aliases: aliases)
    }

    private static func collapseASCIIInitialisms(_ text: String) -> String {
        let pattern = #"(?<![A-Za-z0-9])(?:[A-Z0-9](?:\s+[A-Z0-9]){1,})(?![A-Za-z0-9])"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let out = NSMutableString(string: text)
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: out.length))
        for m in matches.reversed() {
            let token = out.substring(with: m.range).replacingOccurrences(of: " ", with: "")
            out.replaceCharacters(in: m.range, with: token)
        }
        return out as String
    }

    private func postProcessRefinedFinal(_ text: String) -> String {
        let normalized = SherpaASR.normalizeCJK(text)
        let collapsed = Self.collapseASCIIInitialisms(normalized)
        return applyFinalHotwordReplacement(collapsed)
    }

    private func previewDisplayForDeferredCloud(_ text: String) -> String {
        postProcessRefinedFinal(text)
    }

    private func configuredCloudRefiner() -> CloudRefiner? {
        guard store.cloudEnabled else { return nil }
        let cloud = CloudRefiner(baseURL: store.cloudBaseURL, model: store.cloudModel, apiKey: store.cloudApiKey,
                                 temperature: store.cloudTemperature, maxTokens: store.cloudMaxTokens,
                                 provider: store.cloudProvider)
        return cloud.isReady ? cloud : nil
    }

    private func cloudOnlyPolishEnabled() -> Bool {
        !store.polishPaused && !store.refinerEnabled && configuredCloudRefiner() != nil
    }

    private func rawSessionText() -> String {
        let committed = sessionChunks.map(\.raw).joined()
        return committed + sessionTailRaw
    }

    private func shouldUseDeferredCloudLongForm(_ rawText: String) -> Bool {
        guard configuredCloudRefiner() != nil else { return false }
        return rawText.trimmingCharacters(in: .whitespacesAndNewlines).count >= cloudLongFormThreshold
    }

    private func smartEnhancementEnabled() -> Bool {
        !store.polishPaused && store.refinerEnabled && configuredCloudRefiner() != nil
    }

    private func shouldRunSessionWideCloudPass() -> Bool {
        smartEnhancementEnabled() || cloudOnlyPolishEnabled()
    }

    private func polishRuntimeEnabled() -> Bool {
        !store.polishPaused && (refinerActive || configuredCloudRefiner() != nil)
    }

    private func shouldRunDeferredCloudPass() -> Bool {
        sessionLongFormMode
    }

    private func splitRefineChunks(_ text: String, limit: Int) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed.isEmpty ? [] : [trimmed] }
        let chars = Array(trimmed)
        let punct = Set<Character>(["。", "！", "？", "；", ".", "!", "?", ";", "\n"])
        var out: [String] = []
        var start = 0
        while start < chars.count {
            let end = min(start + limit, chars.count)
            if end == chars.count {
                let tail = String(chars[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !tail.isEmpty { out.append(tail) }
                break
            }
            var split = end
            var cursor = end - 1
            while cursor > start {
                if punct.contains(chars[cursor]) {
                    split = cursor + 1
                    break
                }
                cursor -= 1
            }
            if split == start { split = end }
            let chunk = String(chars[start..<split]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !chunk.isEmpty { out.append(chunk) }
            start = split
        }
        return out
    }

    private func clearPendingSentenceSeal() {
        sessionPendingSealCandidate = nil
        sessionPendingSealSince = nil
    }

    private func sessionDisplayText() -> String {
        sessionChunks.map(\.display).joined() + sessionPartial
    }

    private func rawSuffixAfterCommitted(_ text: String) -> String {
        guard sessionFlushedRawChars > 0 else { return text }
        let chars = Array(text)
        guard !chars.isEmpty else { return "" }
        let start = min(sessionFlushedRawChars, chars.count)
        guard start < chars.count else { return "" }
        return String(chars[start...])
    }

    private func takeReadyStreamingChunk(from text: String, limit: Int, allowUnstableSentenceSeal: Bool) -> String? {
        let chars = Array(text)
        guard !chars.isEmpty else { return nil }
        let sentencePunct = Set<Character>(["。", "！", "？", "；", ".", "!", "?", ";", "\n"])
        let softPunct = Set<Character>(["，", ",", "、", "：", ":"])
        let shortProtectChars = 18
        let settleMs: TimeInterval = 0.45

        if let idx = chars.lastIndex(where: { sentencePunct.contains($0) }) {
            let candidate = String(chars[...idx])
            if allowUnstableSentenceSeal {
                clearPendingSentenceSeal()
                return candidate
            }
            let trimmedCount = candidate.trimmingCharacters(in: .whitespacesAndNewlines).count
            let settleDelay = trimmedCount <= shortProtectChars ? settleMs : settleMs * 0.66
            if sessionPendingSealCandidate != candidate {
                sessionPendingSealCandidate = candidate
                sessionPendingSealSince = Date()
                return nil
            }
            if let since = sessionPendingSealSince, Date().timeIntervalSince(since) >= settleDelay {
                clearPendingSentenceSeal()
                return candidate
            }
            return nil
        }
        clearPendingSentenceSeal()
        guard chars.count > limit else { return nil }
        let softCap = min(limit, chars.count)
        if let idx = chars[..<softCap].lastIndex(where: { softPunct.contains($0) }) {
            return String(chars[...idx])
        }
        return String(chars[..<softCap])
    }

    @discardableResult
    private func consumeReadyStreamingChunks(from rawText: String, generation: Int,
                                             allowUnstableSentenceSeal: Bool) -> String {
        var remainder = rawText
        var appendedAny = false
        let sessionWideCloud = shouldRunSessionWideCloudPass()
        let deferredCloud = !sessionWideCloud && (sessionLongFormMode || shouldUseDeferredCloudLongForm(rawSessionText() + rawText))
        if deferredCloud { sessionLongFormMode = true }
        while let rawChunk = takeReadyStreamingChunk(from: remainder,
                                                     limit: store.refineChunkChars,
                                                     allowUnstableSentenceSeal: allowUnstableSentenceSeal) {
            let trimmed = rawChunk.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { break }
            if refinerActive && !deferredCloud {
                _ = appendChunk(raw: trimmed, display: trimmed, polishing: false, sealed: false)
            } else {
                let preview = (sessionWideCloud || deferredCloud) ? previewDisplayForDeferredCloud(trimmed) : corrected(trimmed)
                _ = appendChunk(raw: trimmed, display: preview, polishing: false, sealed: true)
            }
            appendedAny = true
            sessionFlushedRawChars += rawChunk.count
            let chars = Array(remainder)
            remainder = rawChunk.count < chars.count ? String(chars[rawChunk.count...]) : ""
        }
        if appendedAny && refinerActive && !deferredCloud {
            scheduleEditableWindowPolish(generation: generation)
        }
        return remainder
    }

    private func flushReadyStreamingChunks(from rawText: String, generation: Int, isFinal: Bool) {
        let remainder = consumeReadyStreamingChunks(from: rawSuffixAfterCommitted(rawText),
                                                    generation: generation,
                                                    allowUnstableSentenceSeal: isFinal)
        sessionTailRaw = remainder
        if refinerActive {
            sessionPartial = remainder
        } else if shouldRunSessionWideCloudPass() || sessionLongFormMode {
            sessionPartial = previewDisplayForDeferredCloud(remainder)
        } else {
            sessionPartial = corrected(remainder, isFinal: false)
        }
    }

    private func anyChunkPolishing() -> Bool {
        sessionChunks.contains(where: \.polishing)
    }

    private func anySessionPolishing() -> Bool {
        anyChunkPolishing() || sessionWindowPolishTask != nil || sessionLongFormTask != nil
    }

    private func cancelWindowPolishForWholeSessionPass() {
        sessionWindowPolishTask?.cancel()
        sessionWindowPolishTask = nil
        sessionWindowPolishToken += 1
        for idx in sessionChunks.indices { sessionChunks[idx].polishing = false }
    }

    private func updateHistoryForSession(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let id = sessionHistoryID {
            history.update(id: id, text: trimmed)
        } else {
            sessionHistoryID = history.append(trimmed, ephemeral: !store.historyEnabled)
        }
    }

    private func renderSessionText(replaceFromChunkIndex: Int? = nil) {
        let text = store.outputTraditional ? Hant.s2t(sessionDisplayText()) : sessionDisplayText()
        hudModel.partialText = text
        switch sessionSink {
        case .focusedInsert:
            if let replaceFromChunkIndex {
                let safeIndex = min(max(replaceFromChunkIndex, 0), sessionChunks.count)
                let stablePrefix = sessionChunks[..<safeIndex].map(\.display).joined()
                let stableText = store.outputTraditional ? Hant.s2t(stablePrefix) : stablePrefix
                inserter.replaceFromPrefixCount(stableText.count, to: text)
            } else {
                inserter.update(text)
            }
            if store.clipboardOverwrite, !text.isEmpty { Paste.setClipboard(text) }
        case .clipboardOnly:
            if text != sessionLastClipboard, !text.isEmpty {
                Paste.setClipboard(text)
                sessionLastClipboard = text
            }
        }
        if sessionStopped {
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                hudModel.reset()
                hideHUD(after: 0)
                setStatusIcon(engineReady ? "🎙" : "⏳")
                return
            }
            updateHistoryForSession(text)
            if anySessionPolishing() {
                hudModel.phase = .polishing
            } else {
                hudModel.phase = .done
                setStatusIcon(engineReady ? "🎙" : "⏳")
                hideHUD(after: doneStaySeconds())
            }
        } else if text.isEmpty {
            hudModel.phase = .empty
        } else {
            hudModel.phase = .speaking
        }
    }

    private func cancelSessionPolishTasks() {
        sessionWindowPolishTask?.cancel()
        sessionWindowPolishTask = nil
        sessionLongFormTask?.cancel()
        sessionLongFormTask = nil
        sessionWindowPolishToken += 1
        for idx in sessionChunks.indices { sessionChunks[idx].polishing = false }
    }

    private func resetSessionState() {
        cancelSessionPolishTasks()
        sessionChunks.removeAll()
        sessionPartial = ""
        sessionStopped = false
        sessionHistoryID = nil
        sessionLastClipboard = ""
        sessionRawLog.removeAll()
        sessionFlushedRawChars = 0
        sessionTailRaw = ""
        sessionLongFormMode = false
        clearPendingSentenceSeal()
    }

    private func appendChunk(raw: String, display: String, polishing: Bool, sealed: Bool) -> UUID {
        let id = UUID()
        sessionChunks.append(SessionChunk(id: id, raw: raw, display: display, polishing: polishing, sealed: sealed))
        return id
    }

    @discardableResult
    private func replaceChunkRange(_ range: Range<Int>, raw: String, display: String,
                                   polishing: Bool, sealed: Bool) -> Int {
        let lower = min(max(range.lowerBound, 0), sessionChunks.count)
        let upper = min(max(range.upperBound, lower), sessionChunks.count)
        let replacement = SessionChunk(id: UUID(), raw: raw, display: display, polishing: polishing, sealed: sealed)
        sessionChunks.replaceSubrange(lower..<upper, with: [replacement])
        return lower
    }

    private func editableWindowStartIndex() -> Int {
        max(sessionChunks.count - 3, 0)
    }

    private func scheduleEditableWindowPolish(generation: Int) {
        guard refinerActive, !sessionChunks.isEmpty else { return }
        let start = editableWindowStartIndex()
        for idx in sessionChunks.indices {
            let sealed = idx < start
            sessionChunks[idx].sealed = sealed
            if sealed { sessionChunks[idx].polishing = false }
        }

        sessionWindowPolishTask?.cancel()
        sessionWindowPolishToken += 1
        let token = sessionWindowPolishToken
        let end = sessionChunks.count
        let window = Array(sessionChunks[start..<end])
        let rawSpan = window.map(\.raw).joined()
        for idx in start..<end {
            sessionChunks[idx].polishing = true
        }

        sessionWindowPolishTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let polished = await self.correctedFinalAsync(rawSpan)
            guard !Task.isCancelled,
                  self.sessionGeneration == generation,
                  self.sessionWindowPolishToken == token else { return }
            let final = polished.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? self.postProcessRefinedFinal(rawSpan)
                : polished
            _ = self.replaceChunkRange(start..<end, raw: rawSpan, display: final, polishing: false, sealed: false)
            self.sessionWindowPolishTask = nil
            self.renderSessionText(replaceFromChunkIndex: start)
        }
    }

    private func scheduleDeferredCloudLongForm(generation: Int) {
        guard shouldRunDeferredCloudPass(), let cloud = configuredCloudRefiner() else { return }
        let raw = rawSessionText().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }
        let localPreview = sessionDisplayText().trimmingCharacters(in: .whitespacesAndNewlines)

        cancelWindowPolishForWholeSessionPass()
        sessionLongFormTask?.cancel()
        for idx in sessionChunks.indices { sessionChunks[idx].polishing = true }
        renderSessionText()

        let system = buildCloudLongFormSystem()
        let user = buildCloudComparisonUserPrompt(
            task: "请把下面这一整段输入作为一个整体做最终 refine，并用返回结果直接替换这整段输入。",
            raw: raw,
            localPreview: localPreview
        )

        sessionLongFormTask = Task { @MainActor [weak self] in
            guard let self else { return }
            CloudRequestLog.shared.pendingOriginal = raw
            let polished = await cloud.request(system: system, user: user, logInput: raw)
            guard !Task.isCancelled, self.sessionGeneration == generation else { return }
            let final = polished.map(self.postProcessRefinedFinal) ?? self.previewDisplayForDeferredCloud(raw)
            _ = self.replaceChunkRange(0..<self.sessionChunks.count, raw: raw, display: final, polishing: false, sealed: true)
            self.sessionPartial = ""
            self.sessionTailRaw = ""
            self.sessionLongFormTask = nil
            self.renderSessionText(replaceFromChunkIndex: 0)
        }
    }

    private func scheduleSessionWideCloudPolish(generation: Int) {
        guard shouldRunSessionWideCloudPass(), let cloud = configuredCloudRefiner() else { return }
        let raw = rawSessionText().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }
        let current = sessionDisplayText().trimmingCharacters(in: .whitespacesAndNewlines)

        cancelWindowPolishForWholeSessionPass()
        sessionLongFormTask?.cancel()
        for idx in sessionChunks.indices { sessionChunks[idx].polishing = true }
        renderSessionText()

        let system = store.refinerEnabled ? buildSmartEnhancementSystem() : buildCloudLongFormSystem()
        let user = buildCloudComparisonUserPrompt(
            task: "请把这次从按下热键开始到结束的整段输入作为一个整体做最终 refine，并用返回结果直接替换这整段输入。",
            raw: raw,
            localPreview: current
        )

        sessionLongFormTask = Task { @MainActor [weak self] in
            guard let self else { return }
            CloudRequestLog.shared.pendingOriginal = raw
            let polished = await cloud.request(system: system, user: user, logInput: raw)
            guard !Task.isCancelled, self.sessionGeneration == generation else { return }
            let fallback = current.isEmpty ? self.previewDisplayForDeferredCloud(raw) : current
            let final = polished.map(self.postProcessRefinedFinal) ?? fallback
            _ = self.replaceChunkRange(0..<self.sessionChunks.count, raw: raw, display: final, polishing: false, sealed: true)
            self.sessionPartial = ""
            self.sessionTailRaw = ""
            self.sessionLongFormTask = nil
            self.renderSessionText(replaceFromChunkIndex: 0)
        }
    }

    private func finalizePendingSessionTail(generation: Int) {
        guard sessionGeneration == generation else { return }
        let rawTail = sessionTailRaw.isEmpty ? sessionPartial : sessionTailRaw
        let trimmed = rawTail.trimmingCharacters(in: .whitespacesAndNewlines)
        sessionTailRaw = ""
        sessionPartial = ""
        guard !trimmed.isEmpty else { return }
        if refinerActive && !sessionLongFormMode {
            _ = appendChunk(raw: trimmed, display: trimmed, polishing: false, sealed: false)
            scheduleEditableWindowPolish(generation: generation)
        } else {
            let preview = (shouldRunSessionWideCloudPass() || sessionLongFormMode)
                ? previewDisplayForDeferredCloud(trimmed)
                : corrected(trimmed)
            _ = appendChunk(raw: trimmed, display: preview, polishing: false, sealed: true)
        }
    }

    private func armFinalizeFallback() {
        finalizeFallbackWork?.cancel()
        let generation = sessionGeneration
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.sessionGeneration == generation, self.sessionStopped else { return }
            self.finalizePendingSessionTail(generation: generation)
            if self.shouldRunSessionWideCloudPass() {
                self.scheduleSessionWideCloudPolish(generation: generation)
            } else if self.shouldRunDeferredCloudPass() {
                self.scheduleDeferredCloudLongForm(generation: generation)
            }
            self.renderSessionText()
        }
        finalizeFallbackWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    private func armEmptyFinalizeFallback() {
        finalizeFallbackWork?.cancel()
        let generation = sessionGeneration
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.sessionGeneration == generation, self.sessionStopped else { return }
            let hasOutput = !self.sessionDisplayText().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if !hasOutput {
                self.hudModel.reset()
                self.hideHUD(after: 0)
                self.setStatusIcon(self.engineReady ? "🎙" : "⏳")
                return
            }
            self.finalizePendingSessionTail(generation: generation)
            if self.shouldRunSessionWideCloudPass() {
                self.scheduleSessionWideCloudPolish(generation: generation)
            } else if self.shouldRunDeferredCloudPass() {
                self.scheduleDeferredCloudLongForm(generation: generation)
            }
            self.renderSessionText()
        }
        finalizeFallbackWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    /// 配置 AI 润色(Beta)后端:开启 + 模型就绪 → 异步加载 LlamaRefiner;否则 backend=nil(no-op),
    /// 开启但模型缺失时触发在线下载。每次启动 + 设置变化(经 refreshCorrections)时调用。
    private func refreshRefiner() {
        CloudRequestLog.shared.enabled = store.cloudLogEnabled   // 同步「记录请求」开关
        // 菜单栏快捷开关「暂停 AI 润色」:总开关,置 true 时直接 no-op(保留云端/本地配置不动)。
        if store.polishPaused { Refiner.shared.backend = nil; return }
        // 常规二次 refine 的优先级:
        // 1) 本地开了 → 仅本地参与逐段 chunk refine
        // 2) 云端模式/智能增强 → 改为会话结束后的整段 refine,不挂到 Refiner.shared 上逐段执行
        // 3) 都不可用 → no-op
        // 本地 llama 润色仅 Apple Silicon(arm64)启用;Intel(x86_64 切片)走云端,本地灰显不可开。
        #if VIBE_LLAMA && arch(arm64)
        if store.refinerEnabled {
            Refiner.shared.timeout = 4    // 本地 llama 快,4s 足够
            Refiner.shared.systemProvider = { Refiner.systemPrompt }   // CPM5 官方固定 system prompt(开发者 corrector.py)
            if ModelPaths.refinerAvailable() {
                if !(Refiner.shared.backend is LlamaRefiner) {
                    let path = ModelPaths.refinerModelPath()
                    Task.detached(priority: .utility) {
                        let b = LlamaRefiner(modelPath: path)          // 后台加载,不卡主线程
                        await MainActor.run { Refiner.shared.backend = b }
                    }
                }
            } else {
                Refiner.shared.backend = nil
                ModelDownloader.shared.startRefinerDownload()           // 缺模型 → 在线拉
            }
            return
        }
        #endif
        Refiner.shared.backend = nil
    }

    /// 云端 system:取当前模板(自动/自定义)→ 替换 {{hotwords}}(词典)、{{date}}(今天),保留
    /// {{transcript}}(由 CloudRefiner 在 refine 时替换为转写)。
    private func buildCloudSystem(overrideTemplateId: String? = nil) -> String {
        let lang = L10n.resolve(stored: store.storedLang)   // 内置默认提示词随 UI 语言
        let tpl: String
        if let ov = overrideTemplateId, let c = templateContent(id: ov, lang: lang) {
            tpl = c   // 模板快捷键:套用该模板,覆盖当前选中
        } else if store.cloudActiveTemplate == "auto" {
            let ovr = store.cloudAutoOverride
            tpl = ovr.isEmpty ? buildAutoPrompt(store.cloudMods, lang: lang) : ovr
        } else if let c = templateContent(id: store.cloudActiveTemplate, lang: lang) {
            tpl = c
        } else {
            tpl = buildAutoPrompt(store.cloudMods, lang: lang)
        }
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
        return PromptFill.staticTokens(tpl, hotwords: combinedHotwordsText(), date: df.string(from: Date()),
                                       changes: currentRuleChanges)
    }

    private func buildCloudLongFormSystem() -> String {
        let base = buildCloudSystem()
        return """
\(base)

补充要求:
- 当前输入较长,请先通读全文,再做整段级二次 refine,不要只看局部。
- 你会同时收到两份输入:「原始 ASR」和「当前本地结果」。
- 请以「原始 ASR」为主判断真实内容,以「当前本地结果」为辅做参考,吸收其中已经修正正确的部分。
- 这不是摘要任务,不要压缩成总结,不要明显缩短内容,不要改写成另一种表达风格。
- 允许做的事只有:修正转写错误、消除口语赘余、处理自我回改、捋顺局部逻辑、补全标点、合理分段和格式化。
- 专有名词、技术名词和领域词按热词规范统一。
- 如果内容天然适合条目化,可以整理成分段、项目符号或编号列表,但不要丢信息。
- 只输出最终文本,不要解释。
"""
    }

    private func buildCloudComparisonUserPrompt(task: String, raw: String, localPreview: String) -> String {
        """
\(task)

<raw_asr>
\(raw)
</raw_asr>

<local_result>
\(localPreview.isEmpty ? "(空)" : localPreview)
</local_result>
"""
    }

    private func buildSmartEnhancementSystem() -> String {
        return """
你现在执行的是一个文本优化任务。

你会收到两段文本：
1. `<raw_asr>`：原始语音输入的识别结果。它通常信息最全，但可能很乱，包含错字、重复、口语词、改口、解释性补充和不完整表达。
2. `<local_result>`：对同一段内容做过初步 refine 后的结果。它通常更清楚、更顺，但可能丢失信息，尤其可能漏掉改口、补充说明、解释性描述，以及某些专有名词修正线索。

你的目标是：
- 先结合 `<local_result>` 理解用户大致真正想表达的意思。
- 再回到 `<raw_asr>`，基于其中更完整的信息做最终 refine。
- 最终输出应当是用户真正想说、逻辑通顺、书写明确的最终文本。

工作要求：
- 以 `<raw_asr>` 为信息主源，以 `<local_result>` 为理解辅助。
- 如果两者冲突，优先保留 `<raw_asr>` 中更完整、更能解释上下文的信息，同时吸收 `<local_result>` 中已经明确正确的表达。
- 删除 filler words、语气词、口头禅、结巴重复和无意义重复。
- 做 ITN：把数字、日期、时间、金额、百分比、英文缩写、大小写等整理成自然书写形式。
- 修正识别错误、同音误写、断句错误和上下文不通顺的词句，得到最合理的最终写法。
- 正确处理改口和自我修正：如果后文推翻、替换或修正了前文，必须同步改写前文，只保留最终成立的版本。
- 正确处理解释性说明：如果说话人在解释某个词、名字或术语怎么写，必须先理解这段解释是在指代前后文中的哪个词，然后把那个词改成正确写法，而不是机械保留解释原话。
- 解释性说明本身也可能被识别错，所以不能只按字面替换；要结合上下文理解说话人到底在解释哪个词、想确定什么写法。
- 对于指代不清的“那个字”“前面那个词”“就是这个写法”“X的X”这类表达，要结合整段上下文把被解释对象补全并明确写出来。
- 如果解释性说明只是为了纠正写法，最终文本里通常不应保留这段解释过程；只保留修正后的结果。只有当这段解释本身就是内容的一部分时，才保留。
- 可以补标点、理顺句子、整理段落；如果内容天然适合列表，可以整理成列表，但不要丢信息。

输出要求：
- 不要总结。
- 不要明显缩短内容。
- 不要改写成另一种风格。
- 不要添加原文没有的新事实。
- 只输出最终文本，不要解释。
"""
    }

    private func showSimpleAlert(title: String, info: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = info
        alert.addButton(withTitle: "好")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
    /// 解析模板内容:锁定内置「口语转书面」(t1)随 UI 语言实时生成;自定义模板读用户存储原文。
    private func templateContent(id: String, lang: Lang) -> String? {
        if id == LocalizedPrompts.seedTemplateId { return LocalizedPrompts.seed(lang: lang).content }
        return AppDelegate.cloudTemplate(store.cloudTemplatesJSON, id: id)
    }
    static func cloudTemplate(_ json: String, id: String) -> String? {
        guard let data = json.data(using: .utf8),
              let arr = try? JSONDecoder().decode([PromptTemplate].self, from: data) else { return nil }
        return arr.first { $0.id == id }?.content
    }

    /// Parse the snippets JSON ([{"t":trigger,"x":text}]) into replacement rules.
    static func parseSnippets(_ json: String) -> [Replacements.Rule] {
        guard let data = json.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: String]] else { return [] }
        return arr.compactMap { d in
            guard let t = d["t"], !t.isEmpty, let x = d["x"] else { return nil }
            return Replacements.Rule(from: t, to: x)
        }
    }
    /// Apply post-recognition corrections to recognized text: pinyin homophone
    /// normalization → literal replacement rules → (final only) number ITN.
    /// `isFinal` gates ITN, which must NOT run on streaming partials (digits would
    /// jump as you speak); pinyin/replacements are idempotent and run on both.
    private func corrected(_ t: String, isFinal: Bool = true) -> String {
        var s = PinyinNormalizer.shared.normalize(t)
        if !replacementRules.isEmpty { s = Replacements.apply(s, replacementRules) }
        if isFinal {
            if store.defillerEnabled { s = Defiller.clean(s) }   // strip fillers first
            if store.itnEnabled { s = ChineseITN.normalize(s) }  // then normalize numbers
            if !snippetRules.isEmpty { s = Replacements.expand(s, snippetRules) }  // expand snippets last (space-tolerant trigger, eats trailing 。)
            s = applyFinalHotwordReplacement(s)
        }
        return s
    }

    /// AI 路径:原始 ASR → Refiner → CJK 去空格 / ASCII 首字母词并写 / final hotword。
    /// 不再先跑本地 replacement / 拼音 / ITN / Defiller / snippet。
    /// `Refiner.polish` 内部未就绪/超时/护栏不过 → 原样返回,随后仍会走最终热词规范化。
    private func correctedFinalAsync(_ t: String) async -> String {
        let raw = t
        currentRuleChanges = "(无,AI 路径未应用本地规则)"
        // 请求日志的 input 用「原始 ASR」(引擎原始输出 raw,不含任何规则)。
        CloudRequestLog.shared.pendingOriginal = raw
        let polished = await Refiner.shared.polish(raw)
        return postProcessRefinedFinal(polished)
    }
    /// 描述本地规则对识别文本做的改动,供 {{changes}} 注入提示词,让大模型复核纠错。
    static func describeRuleChanges(raw: String, afterPinyin: String, afterRepl: String) -> String {
        var lines: [String] = []
        if afterPinyin != raw { lines.append("· 同音字纠正:「\(raw)」→「\(afterPinyin)」") }
        if afterRepl != afterPinyin { lines.append("· 替换规则:「\(afterPinyin)」→「\(afterRepl)」") }
        return lines.isEmpty ? "(无,本地规则未改动)" : lines.joined(separator: "\n")
    }

    /// 完成一段 final:记录 + 屏显 + 插入。抽出以便"同步路径"与"refiner 异步路径"共用。
    /// refiner 关时,行为与改造前的 onFinal 完全等价(零回归)。
    private func finishFinal(rawText: String, final rawFinal: String) {
        // 「输出转繁体」:所有处理完成后,最终结果以繁体字形输出。
        let final = store.outputTraditional ? Hant.s2t(rawFinal) : rawFinal
        recordFinal(final)
        hudModel.partialText = final
        if store.insertMethod == "type" {
            // 逐字模式:refiner 开(云端或本地)→ 一次性回改成润色版(用户已接受"说完整理");
            // refiner 关 → 维持原行为,只 converge 到 streaming-level,不回改 final-only 修正。
            if refinerActive {
                inserter.update(final)
            } else {
                let s = corrected(rawText, isFinal: false)
                inserter.update(store.outputTraditional ? Hant.s2t(s) : s)
            }
            if store.clipboardOverwrite { Paste.setClipboard(final) }
        } else {
            Paste.insert(final, restore: !store.clipboardOverwrite)
        }
    }

    /// 润色返回(或用户点「立即插入」)→ 收尾插入 + 清状态 + HUD 收。
    /// 用 pendingPolishRaw 作单次守卫:两条路径(完成 / 立即插入)谁先到谁收,另一条 no-op。
    private func finalizePolish(final: String) {
        guard let raw = pendingPolishRaw else { return }
        pendingPolishRaw = nil; pendingPolishRule = nil
        currentSessionTemplateId = nil   // 本次模板覆盖用完即清(systemProvider 已在 polish 时读过)
        polishTask?.cancel(); polishTask = nil
        finalizeFallbackWork?.cancel(); finalizeFallbackWork = nil
        cancelPolishSlow()
        hudModel.polishSlow = false; hudModel.polishHint = nil
        finishFinal(rawText: raw, final: final)
        if store.insertMethod != "type" {
            if refinerActive {
                lastRawASR = raw
                lastInserted = store.outputTraditional ? Hant.s2t(final) : final
            }
            hudModel.canRevise = false
            hudModel.phase = .done
            hideHUD(after: doneStaySeconds())
        }
        setStatusIcon(engineReady ? "🎙" : "⏳")
    }

    /// 重润色可选模板:⚡自动 + 自定义(内置 t1 随 UI 语言显示名)。
    private func makeReviseTemplates() -> [HUDModel.ReviseTemplate] {
        var out: [HUDModel.ReviseTemplate] = [.init(id: "auto", name: L10n.shared.t("llm.tpl.auto"))]
        let lang = L10n.resolve(stored: store.storedLang)
        for t in AppDelegate.decodeTemplates(store.cloudTemplatesJSON) {
            let name = (t.id == LocalizedPrompts.seedTemplateId) ? LocalizedPrompts.seed(lang: lang).name : t.name
            out.append(.init(id: t.id, name: name))
        }
        return out
    }

    /// HUD「撤销」:回删刚插入的文本(假设光标仍在插入处之后),收 HUD。
    private func undoLastInsertion() {
        guard let inserted = lastInserted, !inserted.isEmpty else { return }
        Paste.backspace(inserted.count)
        lastInserted = nil; lastRawASR = nil
        hudModel.canRevise = false
        hudModel.phase = .cancel
        hideHUD(after: 0.8)
    }

    /// HUD「换模板重润色」:回删旧文本 → 用指定模板对原始 ASR 重跑润色 → 插入新文本。
    private func repolishLast(templateId: String) {
        guard let raw = lastRawASR, let old = lastInserted else { return }
        Paste.backspace(old.count)
        hudModel.canRevise = false
        hudModel.phase = .polishing
        currentSessionTemplateId = templateId
        polishTask?.cancel()
        polishTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let polished = await self.correctedFinalAsync(raw)
            if Task.isCancelled { return }
            self.currentSessionTemplateId = nil
            let final = self.store.outputTraditional ? Hant.s2t(polished) : polished
            Paste.insert(final, restore: !self.store.clipboardOverwrite)
            self.lastInserted = final
            self.hudModel.partialText = final
            self.hudModel.canRevise = false
            self.hudModel.phase = .done
            self.hideHUD(after: self.doneStaySeconds())
        }
    }

    /// HUD「立即插入 ✓」:不再等大模型,用已备好的规则版立即插入。
    private func insertNowFromHUD() {
        guard let rule = pendingPolishRule else { return }
        finalizePolish(final: rule)
    }

    /// 润色等待超过 1s 仍未返回 → 判定「过慢」:显示「立即插入」(并让 HUD 可点)+ 提示更换服务商。
    private func armPolishSlow() {
        cancelPolishSlow()
        let w = DispatchWorkItem { [weak self] in
            guard let self, self.pendingPolishRaw != nil else { return }
            self.hudModel.polishSlow = true
            self.hudModel.polishHint = "AI 大模型润色过慢，建议更换大模型服务商"
        }
        slowWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: w)
    }
    private func cancelPolishSlow() { slowWork?.cancel(); slowWork = nil }

    private func beginDictation() {
        guard !onboardingActive, !inTry, !onCallActive else { return }
        guard !micMuted else { toggleDictating = false; return }   // 临时静音:忽略本次触发
        guard engineReady, let engine else { return }
        lastRawASR = nil; lastInserted = nil   // 新一段开始 → 作废上一段的「撤销 / 重润色」
        cancelSessionPolishTasks()
        pendingPolishRaw = nil; pendingPolishRule = nil
        finalizeFallbackWork?.cancel(); finalizeFallbackWork = nil
        inserter.reset()
        sessionGeneration += 1
        resetSessionState()
        sessionSink = Permissions.hasTextInputFocus() ? .focusedInsert : .clipboardOnly

        engine.onPartial = { [weak self] text in
            DispatchQueue.main.async {
                guard let self else { return }
                self.finalizeFallbackWork?.cancel()
                self.flushReadyStreamingChunks(from: text, generation: self.sessionGeneration, isFinal: false)
                self.renderSessionText()
            }
        }
        engine.onFinal = { [weak self] text in
            DispatchQueue.main.async {
                guard let self else { return }
                self.finalizeFallbackWork?.cancel()
                let generation = self.sessionGeneration
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    self.sessionRawLog.append(text)
                    self.flushReadyStreamingChunks(from: text, generation: generation, isFinal: true)
                }
                self.finalizePendingSessionTail(generation: generation)
                if self.sessionStopped {
                    if self.shouldRunSessionWideCloudPass() {
                        self.scheduleSessionWideCloudPolish(generation: generation)
                    } else if self.shouldRunDeferredCloudPass() {
                        self.scheduleDeferredCloudLongForm(generation: generation)
                    }
                }
                self.renderSessionText()
            }
        }

        hudModel.reset()
        hudModel.phase = .empty
        hudModel.elapsed = "0:00"
        if case .clipboardOnly = sessionSink {
            hudModel.polishHint = "当前没有可写入光标，结果会持续写入剪贴板"
        } else {
            hudModel.polishHint = nil
        }
        sessionStart = Date()
        startElapsedTimer()
        // 悬浮条对所有模式都显示——逐字模式也需要它做「在听 / 已锁定」的反馈(否则轻点/单击
        // 切换没有任何提示)。插入走 StreamingInserter 自己的串行队列、与主线程 60fps 无关,
        // 不再像早期那样掉键。
        showHUD()
        setStatusIcon("🔴")

        engine.startSession()
        if store.cueEnabled { CueSound.shared.play(theme: store.cueTheme, start: true) }
        do {
            mic.preferredDeviceUID = store.inputDeviceUID
            try mic.start()
        } catch {
            stopElapsedTimer()
            hudModel.fail(icon: "🎙", title: L10n.shared.t("hud.micFail"), reason: "\(error.localizedDescription)")
            showHUD()   // always surface mic errors, even in no-HUD streaming mode
            setStatusIcon("🎙")
            hideHUD(after: 1.5)
        }
    }

    private func endDictation() {
        toggleDictating = false   // 任何结束路径都复位切换态
        hybridLatched = false; hybridPressAt = nil   // 复位智能模式锁定态
        guard !onboardingActive, !inTry, !onCallActive else { return }
        guard engineReady else { return }
        mic.stop()
        stopElapsedTimer()
        sessionStopped = true
        setStatusIcon(anySessionPolishing() ? "✍️" : "🎙")
        hudModel.phase = anySessionPolishing() ? .polishing : .finalizing

        // endSession() finalizes the utterance and fires onFinal on the main queue,
        // which performs the insert (streamed or one-shot paste) AND records history.
        // Do NOT read a buffer synchronously here — onFinal hasn't run yet (that race
        // was the "shows text but never inserts / history empty" bug).
        engine?.endSession()
        if sessionDisplayText().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            armEmptyFinalizeFallback()
        } else {
            armFinalizeFallback()
        }
        if store.cueEnabled { CueSound.shared.play(theme: store.cueTheme, start: false) }
    }

    /// Append a final to history (if enabled) + the Pad (if enabled).
    private func recordFinal(_ text: String) {
        // Always record. When history saving is OFF the entry is ephemeral (kept 60s
        // with a countdown, never persisted) so a long unsaved dictation isn't lost.
        history.append(text, ephemeral: !store.historyEnabled)
    }

    // ============================================================
    // OnCall — always-on hands-free dictation (持续候机)
    // ============================================================

    private var onCallActive = false

    /// Start/stop the always-on OnCall session to match the selected mode. Called
    /// when the engine becomes ready and whenever the dictation mode changes.
    private func applyDictationMode() {
        stopOnCall()
    }

    private var onCallPanel: NSPanel?
    private var onCallSessionWindow: NSWindow?
    /// Live log of the CURRENT OnCall session (cleared on each start). Copy, the
    /// session viewer, and export all read from this — not the whole history.
    private let onCallLog = OnCallLog()
    /// The dictation mode active before OnCall was selected — restored on stop.
    private var modeBeforeOnCall = "paste"

    private func setupOnCallPanel() {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 172),
                            styleMask: [.nonactivatingPanel, .borderless],
                            backing: .buffered, defer: false)
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = false      // interactive: Copy / Stop buttons
        panel.isMovableByWindowBackground = true   // drag it anywhere
        panel.hidesOnDeactivate = false
        let view = OnCallOverlay(
            model: hudModel,
            log: onCallLog,
            onCopy: { [weak self] in
                guard let self else { return }
                Paste.setClipboard(self.onCallClipboardText())   // CURRENT session (ts + text)
            },
            onView: { [weak self] in self?.openOnCallSession() },
            onPause: { [weak self] in self?.toggleOnCallPause() },
            onStop: { [weak self] in self?.confirmStopOnCall() })
        let hosting = NSHostingView(rootView: view.frame(maxWidth: .infinity, maxHeight: .infinity))
        hosting.frame = panel.contentView!.bounds
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting
        onCallPanel = panel
    }

    private func startOnCall() {
        guard engineReady, let engine, !onCallActive, !onboardingActive, !inTry else { return }
        onCallActive = true
        onCallLog.entries = []               // fresh session log
        onCallLog.paused = false
        engine.holdToTalk = false            // hands-free: commit each utterance on silence

        // OnCall does NOT auto-type (too disruptive). It only shows live recognition
        // in the overlay + records every utterance to history (tagged oncall) for
        // safety. The user copies via the overlay's Copy button.
        engine.onPartial = { [weak self] text in
            DispatchQueue.main.async {
                guard let self, self.onCallActive else { return }
                let text = self.corrected(text, isFinal: false)
                self.hudModel.partialText = text
                self.hudModel.phase = .speaking
            }
        }
        engine.onFinal = { [weak self] text in
            DispatchQueue.main.async {
                guard let self, self.onCallActive else { return }
                let text = self.corrected(text)
                self.history.append(text, mode: "oncall", ephemeral: !self.store.historyEnabled)
                self.onCallLog.entries.append(HistoryItem(id: UUID(), text: text.trimmingCharacters(in: .whitespacesAndNewlines), date: Date(), mode: "oncall"))
                self.hudModel.partialText = text
                self.hudModel.phase = .pause
            }
        }

        hudModel.reset()
        hudModel.phase = .empty
        sessionStart = Date()                // drive the overlay's running timer
        startElapsedTimer()
        if onCallPanel == nil { setupOnCallPanel() }
        if let p = onCallPanel, let screen = NSScreen.main {
            let vis = screen.visibleFrame
            let psize = p.frame.size
            p.setFrameOrigin(NSPoint(x: vis.maxX - psize.width - 20,
                                     y: vis.maxY - psize.height - 12))
            p.orderFrontRegardless()
        }
        setStatusIcon("📞")

        engine.startSession()
        if store.cueEnabled { CueSound.shared.play(theme: store.cueTheme, start: true) }
        do { mic.preferredDeviceUID = store.inputDeviceUID; try mic.start() }
        catch {
            hudModel.fail(icon: "🎙", title: L10n.shared.t("hud.micFail"),
                          reason: "\(error.localizedDescription)")
        }
    }

    private func stopOnCall() {
        guard onCallActive else { return }
        stopElapsedTimer()
        mic.stop()
        // Commit any in-flight sentence (VAD hadn't reached silence, ASR still
        // streaming a partial). endSession() flushes it via onFinal — but the normal
        // OnCall handler is guarded on onCallActive (which we clear below) and
        // dispatches async (runs too late). So capture the final SYNCHRONOUSLY here,
        // mirroring stopTrySession(), or the last sentence is lost.
        if let engine {
            engine.onPartial = nil
            engine.onFinal = { [weak self] text in
                guard let self else { return }
                let text = self.corrected(text)
                let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !t.isEmpty else { return }
                self.history.append(text, mode: "oncall", ephemeral: !self.store.historyEnabled)
                self.onCallLog.entries.append(HistoryItem(id: UUID(), text: t, date: Date(), mode: "oncall"))
            }
            engine.endSession()
            if store.cueEnabled { CueSound.shared.play(theme: store.cueTheme, start: false) }
            engine.onFinal = nil
            engine.holdToTalk = true         // restore push-to-talk default
        }
        onCallActive = false
        onCallPanel?.orderOut(nil)
        hudModel.reset()
        setStatusIcon(engineReady ? "🎙" : "⏳")
    }

    /// All OnCall-tagged history, oldest-first, "[timestamp] text" per line — what
    /// the overlay's Copy button puts on the clipboard (the whole standby log, not
    /// just the current sentence).
    private func onCallClipboardText() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return onCallLog.entries
            .map { "[\(f.string(from: $0.date))] \($0.text)" }
            .joined(separator: "\n")
    }

    /// Pause / resume listening without ending the session.
    private func toggleOnCallPause() {
        guard onCallActive else { return }
        if onCallLog.paused {
            try? mic.start()
            onCallLog.paused = false
            setStatusIcon("📞")
        } else {
            mic.stop()
            // Commit the in-flight sentence instead of freezing/dropping it. onCallActive
            // is still true, so the normal onFinal handler records it; the next resume
            // begins a fresh sentence on the first speech onset.
            engine?.endSession()
            onCallLog.paused = true
            setStatusIcon("⏸")
        }
    }

    private func dictationModeName(_ m: String) -> String {
        switch m {
        case "type":   return "逐字插入"
        case "oncall": return "持续候机"
        default:        return "说完插入"
        }
    }


    /// Stop OnCall with a confirmation; on confirm, restore the previous mode and
    /// tell the user which mode is active + the hotkey to trigger it.
    private func confirmStopOnCall() {
        let prevName = dictationModeName(modeBeforeOnCall)
        let hotkey = VibeKeycodes.name(hotkeyKeyCode)
        let alert = NSAlert()
        alert.messageText = "停止候机模式?"
        var info = "停止后听写模式将切回「\(prevName)」,按 \(hotkey) 即可触发听写。"
        if !store.historyEnabled && !onCallLog.entries.isEmpty {
            info += "\n\n你未开启「保存历史」,本次 \(onCallLog.entries.count) 条记录不会永久保存。停止后会自动弹出记录窗,可在那里复制或导出。"
        }
        alert.informativeText = info
        alert.addButton(withTitle: "停止")
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        store.insertMethod = modeBeforeOnCall   // restore the previous mode
        // Nudge an open Settings window to re-read the (now reverted) mode.
        NotificationCenter.default.post(name: Notification.Name("vibeSettingsExternallyChanged"), object: nil)
        stopOnCall()
        openOnCallSession()                     // auto-show this session's transcript
    }

    /// Pop the session viewer: the current session's entries (live), each selectable
    /// for copy, plus export. Re-uses the window if it's already open.
    private func openOnCallSession() {
        if let w = onCallSessionWindow {        // already created — just resurface it
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let hosting = NSHostingController(rootView: OnCallSessionView(log: onCallLog))
        let w = NSWindow(contentViewController: hosting)
        w.title = "OnCall"
        w.styleMask = [.titled, .closable, .resizable]
        w.setContentSize(NSSize(width: 460, height: 420))
        w.isReleasedWhenClosed = false
        w.center()
        onCallSessionWindow = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // ============================================================
    // Onboarding "try it" — in-window dictation (page 1)
    // ============================================================

    private var tryFinalizedPrefix = ""

    func startTrySession() {
        // Fire the contextual mic prompt on first ever press.
        AVCaptureDevice.requestAccess(for: .audio) { _ in }
        guard engineReady, let engine, !inTry else { return }

        inTry = true
        tryFinalizedPrefix = ""

        engine.onPartial = { [weak self] text in
            DispatchQueue.main.async {
                guard let self, self.inTry else { return }
                self.tryHUD.partialText = self.tryFinalizedPrefix + text
                self.tryHUD.phase = .speaking
            }
        }
        engine.onFinal = { [weak self] text in
            DispatchQueue.main.async {
                guard let self, self.inTry else { return }
                self.tryFinalizedPrefix += text
                self.tryHUD.partialText = self.tryFinalizedPrefix
            }
        }

        tryHUD.reset()
        tryHUD.phase = .empty

        engine.startSession()
        do {
            mic.preferredDeviceUID = store.inputDeviceUID
            try mic.start()
        } catch {
            inTry = false
            tryHUD.fail(icon: "🎙", title: L10n.shared.t("hud.micFail"),
                        reason: error.localizedDescription)
        }
    }

    func stopTrySession() {
        guard inTry else { return }
        mic.stop()

        if let engine {
            engine.onPartial = nil
            engine.onFinal = { [weak self] text in self?.tryFinalizedPrefix += text }
            engine.endSession()
            engine.onFinal = nil
        }
        let text = tryFinalizedPrefix
        tryHUD.partialText = text
        tryHUD.phase = text.isEmpty ? .idle : .done
        tryHUD.level = 0
        inTry = false
    }

    // MARK: elapsed clock

    private func startElapsedTimer() {
        stopElapsedTimer()
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let start = self.sessionStart else { return }
                let secs = Int(Date().timeIntervalSince(start))
                self.hudModel.elapsed = HUDModel.formatElapsed(secs)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        elapsedTimer = timer
    }

    private func stopElapsedTimer() {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
    }

    // MARK: window lifecycle

    func windowWillClose(_ notification: Notification) {
        guard let w = notification.object as? NSWindow else { return }
        if w === onboardingWindow {
            onboardingWindow = nil
            onboardingWindowDidDisappear()
        }
        if w === settingsWindow { settingsWindow = nil }
        if w === padWindow { padWindow = nil }
        if w === historyWindow { historyWindow = nil }
        if w === promptStudioWindow { promptStudioWindow = nil }
    }

    // MARK: launch at login

    /// Reconcile the macOS login item with the stored preference (macOS 13+
    /// SMAppService). Best-effort: failures are logged, not fatal.
    private func applyLaunchAtLogin() {
        LaunchAtLogin.setEnabled(store.launchAtLogin)
    }

    /// Remove all local data and move the app bundle to Trash.
    private func performFullUninstall() {
        if inTry { stopTrySession() }
        polishTask?.cancel()
        slowWork?.cancel()
        finalizeFallbackWork?.cancel()
        cancelSessionPolishTasks()

        downloader.cancelAllDownloads()
        history.clearAll()
        pad.clear()

        store.launchAtLogin = false
        applyLaunchAtLogin()

        KeychainStore.delete("cloudApiKey")
        KeychainStore.delete("cloudProfiles")

        if let bundleID = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: bundleID)
        }
        UserDefaults.standard.synchronize()

        let supportDir = ModelPaths.appSupportDir()
        try? FileManager.default.removeItem(at: supportDir)

        let bundleURL = Bundle.main.bundleURL
        var trashedURL: NSURL?
        do {
            try FileManager.default.trashItem(at: bundleURL, resultingItemURL: &trashedURL)
            NSApp.terminate(nil)
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = L10n.shared.t("gen.deleteApp.failTitle")
            alert.informativeText = "\(L10n.shared.t("gen.deleteApp.fail"))\n\(bundleURL.path)"
            alert.addButton(withTitle: L10n.shared.t("ok"))
            alert.runModal()
        }
    }

    /// Confirm before the destructive uninstall flow.
    private func confirmAndDeleteAppAndData() {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = L10n.shared.t("gen.deleteApp.confirmTitle")
        alert.informativeText = L10n.shared.t("gen.deleteApp.confirm")
        alert.addButton(withTitle: L10n.shared.t("gen.deleteApp.action"))
        alert.addButton(withTitle: L10n.shared.t("cancel"))
        if alert.runModal() == .alertFirstButtonReturn {
            performFullUninstall()
        }
    }

    // MARK: helpers

    nonisolated static func rmsLevel(_ samples: [Float]) -> Double {
        guard !samples.isEmpty else { return 0 }
        var sum: Double = 0
        for s in samples { sum += Double(s) * Double(s) }
        let rms = (sum / Double(samples.count)).squareRoot()
        return min(1.0, max(0.0, rms * 6.0))
    }
}

// ============================================================
// VibeUI bridges — connect the SwiftUI surfaces to SettingsStore + Permissions.
// ============================================================

extension AppDelegate: SettingsBridge {
    var showDockIcon: Bool {
        get { store.showDockIcon }
        set { store.showDockIcon = newValue }
    }
    var hotkeyKeyCode: Int { store.hotkeyKeyCode }
    var hotkeyModifierOnly: Bool { store.hotkeyModifierOnly }
    var hotkeyMods: Int { store.hotkeyMods }
    var hotkeyToggleMode: Bool {
        get { store.hotkeyToggleMode }
        set { store.hotkeyToggleMode = newValue }   // setter posts hotkeyChanged → rebuildHotkeys
    }
    func setHotkey(keyCode: Int, modifierOnly: Bool, mods: Int) {
        store.setHotkey(keyCode: keyCode, modifierOnly: modifierOnly, mods: mods)
    }

    // Engine config
    var vadKind: String {
        get { store.vadKind }
        set { store.vadKind = newValue }   // posts engineConfigChanged → rebuild
    }
    var latencyTier: Int {
        get { store.latencyTier }
        set { store.latencyTier = newValue }
    }

    // Dictation behaviour
    var insertMethod: String {
        get { store.insertMethod }
        set {
            if newValue == "oncall" && store.insertMethod != "oncall" {
                modeBeforeOnCall = store.insertMethod   // remember to restore on stop
            }
            store.insertMethod = newValue
            applyDictationMode()
        }
    }
    var clipboardOverwrite: Bool {
        get { store.clipboardOverwrite }
        set { store.clipboardOverwrite = newValue }
    }
    var outputTraditional: Bool {
        get { store.outputTraditional }
        set { store.outputTraditional = newValue }
    }
    var hudStaySeconds: Double {
        get { store.hudStaySeconds }
        set { store.hudStaySeconds = newValue }
    }
    var padWriteEnabled: Bool {
        get { store.padWriteEnabled }
        set { store.padWriteEnabled = newValue }
    }
    var historyEnabled: Bool {
        get { store.historyEnabled }
        set { store.historyEnabled = newValue }
    }
    var launchAtLogin: Bool {
        get { store.launchAtLogin }
        set { store.launchAtLogin = newValue }
    }

    var cueEnabled: Bool {
        get { store.cueEnabled }
        // Preview the cue when the user turns it on.
        set { store.cueEnabled = newValue; if newValue { CueSound.shared.play(theme: store.cueTheme, start: true) } }
    }
    var cueTheme: String {
        get { store.cueTheme }
        // Preview the chosen timbre immediately on switch.
        set { store.cueTheme = newValue; if store.cueEnabled { CueSound.shared.play(theme: newValue, start: true) } }
    }
    var cueVolume: String {
        get { store.cueVolume }
        // Apply the new gain and preview it at that level.
        set {
            store.cueVolume = newValue
            CueSound.shared.gain = CueSound.gain(for: newValue)
            if store.cueEnabled { CueSound.shared.play(theme: store.cueTheme, start: true) }
        }
    }

    // Hotwords (contextual biasing)
    var hotwordsEnabled: Bool {
        get { store.hotwordsEnabled }
        set { store.hotwordsEnabled = newValue }   // posts engineConfigChanged → rebuild
    }
    var hotwordsText: String {
        get { store.hotwordsText }
        set { store.hotwordsText = newValue }       // persist only; applyHotwords() rebuilds
    }
    var hotwordsScore: Double {
        get { store.hotwordsScore }
        set { store.hotwordsScore = newValue }       // persist only
    }
    /// Commit the edited list + score and rebuild the engine so it takes effect.
    func applyHotwords() { store.commitHotwords() }
    var hotwordDomainIDs: [String] {
        get { store.hotwordDomainIDs }
        set { store.hotwordDomainIDs = newValue }
    }
    func applyHotwordDomains(_ ids: [String]) {
        store.hotwordDomainIDs = ids
        refreshCorrections()
        rebuildEngineForConfig()
    }

    // Replacements (post-recognition corrections)
    var replacementsEnabled: Bool {
        get { store.replacementsEnabled }
        set { store.replacementsEnabled = newValue; refreshCorrections() }
    }
    var replacementsText: String {
        get { store.replacementsText }
        set { store.replacementsText = newValue }   // persist only; applyReplacements() commits
    }
    /// Commit edited rules and refresh the live cache (no engine rebuild needed).
    func applyReplacements() { store.commitReplacements(); refreshCorrections() }

    // Homophone (pinyin) correction
    var pinyinFuzzyEnabled: Bool {
        get { store.pinyinFuzzyEnabled }
        set { store.pinyinFuzzyEnabled = newValue; refreshCorrections() }
    }
    // Number normalization (ITN) — pure post-processing, read live in corrected()
    var itnEnabled: Bool {
        get { store.itnEnabled }
        set { store.itnEnabled = newValue }
    }
    // Filler-word removal — pure post-processing, read live in corrected()
    var defillerEnabled: Bool {
        get { store.defillerEnabled }
        set { store.defillerEnabled = newValue }
    }
    // AI 润色(本地 Beta):写 store 即 post(changed) → refreshCorrections → refreshRefiner
    // (开启且模型缺失 → 触发在线下载;就绪 → 后台加载 LlamaRefiner)。
    var refinerEnabled: Bool {
        get { store.refinerEnabled }
        set { store.refinerEnabled = newValue }
    }
    // Voice snippets (trigger → multi-line expansion)
    var snippetsEnabled: Bool {
        get { store.snippetsEnabled }
        set { store.snippetsEnabled = newValue; refreshCorrections() }
    }
    var snippetsJSON: String {
        get { store.snippetsJSON }
        set { store.snippetsJSON = newValue }   // persist only; applySnippets() commits
    }
    // 云端大模型:整包配置在 store/Keychain ↔ UI DTO 之间映射。
    var cloudConfig: CloudConfigDTO {
        get {
            normalizedCloudConfig(
                CloudConfigDTO(enabled: store.cloudEnabled, provider: store.cloudProvider,
                               baseURL: store.cloudBaseURL, model: store.cloudModel,
                               numbers: store.cloudModNumbers, fillers: store.cloudModFillers,
                               restate: store.cloudModRestate, hotwords: store.cloudModHotwords,
                               apiKey: store.cloudApiKey, templatesJSON: store.cloudTemplatesJSON,
                               activeTemplate: store.cloudActiveTemplate, autoOverride: store.cloudAutoOverride,
                               customProvidersJSON: store.cloudCustomProvidersJSON,
                               temperature: store.cloudTemperature, maxTokens: store.cloudMaxTokens,
                               logEnabled: store.cloudLogEnabled, profilesJSON: store.cloudProfilesJSON,
                               templateHotkeysJSON: store.cloudTemplateHotkeysJSON)
            )
        }
        set {
            let normalized = normalizedCloudConfig(newValue)
            store.cloudProvider = normalized.provider; store.cloudBaseURL = normalized.baseURL
            store.cloudModel = normalized.model
            store.cloudModNumbers = normalized.numbers; store.cloudModFillers = normalized.fillers
            store.cloudModRestate = normalized.restate; store.cloudModHotwords = normalized.hotwords
            store.cloudApiKey = normalized.apiKey; store.cloudTemplatesJSON = normalized.templatesJSON
            store.cloudActiveTemplate = normalized.activeTemplate; store.cloudAutoOverride = normalized.autoOverride
            store.cloudCustomProvidersJSON = normalized.customProvidersJSON
            store.cloudTemperature = normalized.temperature; store.cloudMaxTokens = normalized.maxTokens
            store.cloudLogEnabled = normalized.logEnabled
            store.cloudProfilesJSON = normalized.profilesJSON
            store.cloudTemplateHotkeysJSON = normalized.templateHotkeysJSON   // 改动 post hotkeyChanged → 重建快捷键
            store.cloudEnabled = normalized.enabled   // 最后置 enabled,触发一次 refreshRefiner
        }
    }
    private func normalizedCloudConfig(_ config: CloudConfigDTO) -> CloudConfigDTO {
        var normalized = config
        guard normalized.provider == "openai_compatible" else { return normalized }
        let openAI = CloudProvidersUI.find("openai")
        normalized.provider = openAI.key
        let trimmedBaseURL = normalized.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedBaseURL.isEmpty || trimmedBaseURL == "https://your-proxy.example.com/v1" {
            normalized.baseURL = openAI.baseURL
        }
        let trimmedModel = normalized.model.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedModel.isEmpty || trimmedModel == "gpt-4o-mini" {
            normalized.model = openAI.defaultModel
        }
        return normalized
    }
    func testCloud(_ cfg: CloudConfigDTO) async -> CloudTestResult {
        let r = await CloudRefiner.testConnection(baseURL: cfg.baseURL, model: cfg.model, apiKey: cfg.apiKey)
        return CloudTestResult(ok: r.ok, ping: r.ping, add: r.add, msg: r.msg)
    }
    func cloudRecentRequests() -> [CloudReqLogEntry] {
        CloudRequestLog.shared.snapshot().map {
            CloudReqLogEntry(id: $0.id, at: $0.at, provider: $0.provider, baseURL: $0.baseURL, model: $0.model,
                             status: $0.status, ms: $0.ms, input: $0.input, output: $0.output, prompt: $0.prompt)
        }
    }
    func cloudClearRequests() { CloudRequestLog.shared.clear() }
    func applySnippets() { store.commitSnippets(); refreshCorrections() }

    // Microphone input-device picker
    func inputDevices() -> [(uid: String, name: String)] {
        [("", L10n.shared.t("perm.device.default"))] + AudioDevices.inputs().map { ($0.uid, $0.name) }
    }
    var inputDeviceUID: String {
        get { store.inputDeviceUID }
        set { store.inputDeviceUID = newValue }
    }

    // Local share API (共享)
    var apiEnabled: Bool {
        get { store.apiEnabled }
        set { store.apiEnabled = newValue }      // posts apiConfigChanged → restartAPIServer()
    }
    var apiAllowLAN: Bool {
        get { store.apiAllowLAN }
        set { store.apiAllowLAN = newValue }
    }
    var apiKey: String { store.apiKey }
    var apiPort: Int {
        let bound = Int(LocalAPIServer.shared.boundPort)
        return bound > 0 ? bound : store.apiPort   // reflect the actually-bound port (fallback-aware)
    }
    var apiLANHost: String? { store.apiAllowLAN ? AppDelegate.primaryLANIPv4() : nil }
    @discardableResult func regenerateAPIKey() -> String { store.regenerateAPIKey() }

    var modelManager: ModelManagerBridge? { downloader }

    /// Apply a tier selection. If it's already available, the store change posts
    /// engineConfigChanged → rebuild. Otherwise we start the download; the engine
    /// stays on the bundled tier until the download completes, then auto-swaps.
    func selectTier(_ tier: Int) {
        guard let t = LatencyTier(rawValue: tier) else { return }
        store.latencyTier = tier   // persists + posts engineConfigChanged
        if !ModelPaths.tierAvailable(t) {
            downloader.startDownload(t)
            // Observe completion to swap once present.
            observeDownloadCompletion(for: t)
        }
    }

    /// Poll the downloader until the selected tier becomes available, then
    /// rebuild the engine onto it (if it's still the selected tier). Stops on
    /// completion, failure, or if the user picks a different tier.
    private func observeDownloadCompletion(for tier: LatencyTier) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self else { return }
            if self.store.latencyTier != tier.rawValue { return }   // user moved on
            if ModelPaths.tierAvailable(tier) {
                self.rebuildEngineForConfig()                       // swap onto it
            } else if self.downloader.downloadProgress(tier) != nil {
                self.observeDownloadCompletion(for: tier)           // still downloading
            }
            // else: failed / cancelled → stop polling (UI shows the failed state).
        }
    }

    // Live permission reads. (accessibilityGranted()/inputMonitoringGranted()
    // are declared in the OnboardingBridge extension below — identical signatures,
    // so a single implementation satisfies BOTH protocols.)
    func micGranted() -> Bool { Permissions.micState() == .granted }
    func openPermissionSettings(_ which: PermissionKind) {
        switch which {
        case .microphone:      Permissions.openMicrophoneSettings()
        case .accessibility:   Permissions.requestAccessibility()
        case .inputMonitoring: Permissions.requestInputMonitoring()
        }
    }

    func deleteAppAndData() {
        confirmAndDeleteAppAndData()
    }

    /// SettingsBridge: the About tab's "检查更新" button → Sparkle's user-initiated check.
    func checkForUpdates() {
        // Bring the app forward so Sparkle's progress/alert windows are visible
        // (we're an accessory/menu-bar app most of the time).
        NSApp.activate(ignoringOtherApps: true)
        updaterController.checkForUpdates(nil)
    }
}

extension AppDelegate: OnboardingBridge {
    func microphoneState() -> OnboardingPermission {
        switch Permissions.micState() {
        case .granted:       return .granted
        case .notDetermined: return .notDetermined
        case .denied:        return .denied
        }
    }
    func accessibilityGranted() -> Bool { Permissions.accessibilityGranted() }
    func inputMonitoringGranted() -> Bool { Permissions.inputMonitoringGranted() }

    func requestMicrophone() { Permissions.requestMic() }
    func openMicrophoneSettings() { Permissions.openMicrophoneSettings() }
    func requestAccessibility() { Permissions.requestAccessibility() }
    func requestInputMonitoring() { Permissions.requestInputMonitoring() }

    var tryModel: HUDModel { tryHUD }

    func onboardingWindowDidAppear() {
        onboardingActive = true
    }

    func onboardingWindowDidDisappear() {
        if inTry { stopTrySession() }
        onboardingActive = false
    }

    func finishOnboarding() {
        if store.hotwordDomainIDs.isEmpty {
            applyHotwordDomains(["vibe_coding"])
        }
        store.didCompleteOnboarding = true
        closeOnboarding()
    }

    /// OnboardingBridge 只设主键(单键/修饰),不涉及组合 → mods 恒为 0。
    func setHotkey(keyCode: Int, modifierOnly: Bool) {
        setHotkey(keyCode: keyCode, modifierOnly: modifierOnly, mods: 0)
    }
}
