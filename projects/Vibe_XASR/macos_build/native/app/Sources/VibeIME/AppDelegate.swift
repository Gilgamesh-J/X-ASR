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
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {

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
    /// 是否有就绪的润色后端(云端或本地)。判定走异步润色路径,而非看本地开关(云端开关是 cloudEnabled)。
    private var refinerActive: Bool { Refiner.shared.backend?.isReady == true }
    private var settingsWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    private var padWindow: NSWindow?
    private var historyWindow: NSWindow?
    private var statusMenuItem: NSMenuItem!
    private var dockToggleItem: NSMenuItem!
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
        self.hotkey = Hotkey(keycode: CGKeyCode(s.hotkeyKeyCode),
                             modifierOnly: s.hotkeyModifierOnly)
        super.init()
    }

    // MARK: Dictation pass state
    /// Robust streaming inserter — one-char Unicode keystrokes on a serial queue
    /// (replaces the old chunked typeOut that dropped characters).
    private let inserter = StreamingInserter()
    private var elapsedTimer: Timer?
    private var sessionStart: Date?
    private var hideWorkItem: DispatchWorkItem?

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
        wireHotkey()
        _ = hotkey.start()
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
            MainActor.assumeIsolated { self?.restartHotkey() }
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
            MainActor.assumeIsolated { self?.refreshCorrections() }
        }
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

    /// Tear down + recreate the global key listener for a new keycode (live).
    private func restartHotkey() {
        hotkey.stop()
        hotkey = Hotkey(keycode: CGKeyCode(store.hotkeyKeyCode),
                        modifierOnly: store.hotkeyModifierOnly)
        wireHotkey()
        _ = hotkey.start()
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

        statusItem.menu = menu
    }

    /// Re-apply localized titles to the native menu when the UI language changes
    /// (the AppKit NSMenu isn't a SwiftUI view, so it can't observe L10n itself).
    private func relocalizeMenu() {
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
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 120),
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
        hudModel.onInsertNow = { [weak self] in self?.insertNowFromHUD() }
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
        if store.hotwordsEnabled {
            HotwordsStore.writeFile(text: store.hotwordsText, score: store.hotwordsScore, to: hwURL)
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
            let engine = DictationEngine(vad: vad, asr: asr, prerollSec: 1.0)

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

    private func wireHotkey() {
        hotkey.onDown = { [weak self] in
            DispatchQueue.main.async { self?.beginDictation() }
        }
        hotkey.onUp = { [weak self] in
            DispatchQueue.main.async { self?.endDictation() }
        }

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
        PinyinNormalizer.shared.setWords(store.pinyinFuzzyEnabled ? HotwordsStore.normalize(store.hotwordsText) : [])
        refreshRefiner()
    }

    /// 配置 AI 润色(Beta)后端:开启 + 模型就绪 → 异步加载 LlamaRefiner;否则 backend=nil(no-op),
    /// 开启但模型缺失时触发在线下载。每次启动 + 设置变化(经 refreshCorrections)时调用。
    private func refreshRefiner() {
        CloudRequestLog.shared.enabled = store.cloudLogEnabled   // 同步「记录请求」开关
        // 云端优先(开 + Key/URL/模型就绪);否则本地;都不行 → nil(安全 no-op)。
        if store.cloudEnabled {
            let cloud = CloudRefiner(baseURL: store.cloudBaseURL, model: store.cloudModel, apiKey: store.cloudApiKey,
                                     temperature: store.cloudTemperature, maxTokens: store.cloudMaxTokens,
                                     provider: store.cloudProvider)
            if cloud.isReady {
                Refiner.shared.backend = cloud
                Refiner.shared.timeout = 25   // 云端比本地慢得多(网络+生成);本地 0.5s,云端常 3~8s,4s 会误超时回退
                Refiner.shared.systemProvider = { [weak self] in self?.buildCloudSystem() ?? "" }
                return
            }
        }
        // 本地 llama 润色仅 Apple Silicon(arm64)启用;Intel(x86_64 切片)走云端,本地灰显不可开。
        #if VIBE_LLAMA && arch(arm64)
        if store.refinerEnabled {
            Refiner.shared.timeout = 4    // 本地 llama 快,4s 足够
            Refiner.shared.systemProvider = { Refiner.systemPrompt }   // 本地用固定指令
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
    private func buildCloudSystem() -> String {
        let tpl: String
        if store.cloudActiveTemplate == "auto" {
            let ovr = store.cloudAutoOverride
            tpl = ovr.isEmpty ? buildAutoPrompt(store.cloudMods) : ovr
        } else if let c = AppDelegate.cloudTemplate(store.cloudTemplatesJSON, id: store.cloudActiveTemplate) {
            tpl = c
        } else {
            tpl = buildAutoPrompt(store.cloudMods)
        }
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
        return PromptFill.staticTokens(tpl, hotwords: store.hotwordsText, date: df.string(from: Date()),
                                       changes: currentRuleChanges)
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
        }
        return s
    }

    /// 与 `corrected(isFinal: true)` 同序,但在 Defiller 之后、ITN 之前插入 AI 润色(Beta,异步)。
    /// 顺序原因(见 refiner_eval 评估):refiner 会擅自改数字且不稳,故必须排在规则 ITN 之前,
    /// 让数字最终由可靠的 ChineseITN 负责。`Refiner.polish` 内部未就绪/超时/护栏不过 → 原样返回。
    private func correctedFinalAsync(_ t: String) async -> String {
        let raw = t
        var s = PinyinNormalizer.shared.normalize(t)
        let afterPinyin = s
        if !replacementRules.isEmpty { s = Replacements.apply(s, replacementRules) }
        let afterRepl = s
        // 记录本地规则(同音字 / 替换)对识别文本的改动,注入 {{changes}} 让大模型复核(本地可能弄错)。
        currentRuleChanges = AppDelegate.describeRuleChanges(raw: raw, afterPinyin: afterPinyin, afterRepl: afterRepl)
        // 请求日志的 input 用「原始 ASR」(引擎原始输出 raw,不含任何规则)。
        CloudRequestLog.shared.pendingOriginal = raw
        // AI 润色接管「去口水词 + 数字规整」→ 与听写的 Defiller/ITN 互斥,这里都不再跑规则版(UI 已置灰)。
        s = await Refiner.shared.polish(s)                       // ★ AI 润色
        if !snippetRules.isEmpty { s = Replacements.expand(s, snippetRules) }
        return s
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
    private func finishFinal(rawText: String, final: String) {
        recordFinal(final)
        hudModel.partialText = final
        if store.insertMethod == "type" {
            // 逐字模式:refiner 开(云端或本地)→ 一次性回改成润色版(用户已接受"说完整理");
            // refiner 关 → 维持原行为,只 converge 到 streaming-level,不回改 final-only 修正。
            if refinerActive {
                inserter.update(final)
            } else {
                inserter.update(corrected(rawText, isFinal: false))
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
        polishTask?.cancel(); polishTask = nil
        finalizeFallbackWork?.cancel(); finalizeFallbackWork = nil
        cancelPolishSlow()
        hudModel.polishSlow = false; hudModel.polishHint = nil
        hudPanel?.ignoresMouseEvents = true
        finishFinal(rawText: raw, final: final)
        if store.insertMethod != "type" {
            hudModel.phase = .done
            hideHUD(after: 0.8)
        }
        setStatusIcon(engineReady ? "🎙" : "⏳")
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
            self.hudPanel?.ignoresMouseEvents = false
            self.hudModel.polishHint = "AI 大模型润色过慢，建议更换大模型服务商"
        }
        slowWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: w)
    }
    private func cancelPolishSlow() { slowWork?.cancel(); slowWork = nil }

    private func beginDictation() {
        guard !onboardingActive, !inTry, !onCallActive else { return }
        guard engineReady, let engine else { return }
        // 上一段润色还没返回就又开始 → 先把上一段用规则版立即插入,避免丢字 / HUD 错乱。
        if pendingPolishRaw != nil, let rule = pendingPolishRule { finalizePolish(final: rule) }
        finalizeFallbackWork?.cancel(); finalizeFallbackWork = nil
        inserter.reset()

        engine.onPartial = { [weak self] text in
            DispatchQueue.main.async {
                guard let self else { return }
                let text = self.corrected(text, isFinal: false)
                self.hudModel.partialText = text
                self.hudModel.phase = .speaking
                // Streaming insertion: type the recognized text into the focused app
                // AS IT ARRIVES (diff vs what we've already typed). "type" path only —
                // "paste" inserts the whole final once on release.
                if self.store.insertMethod == "type" { self.inserter.update(text) }
            }
        }
        engine.onFinal = { [weak self] text in
            DispatchQueue.main.async {
                guard let self else { return }
                // 无就绪润色后端(云端或本地)→ 原同步路径(零回归)。
                // 注:此前误用本地开关 store.refinerEnabled 判定 → 云端只开 cloudEnabled 时被跳过、从不调用;
                //     改用 refinerActive(后端就绪即可)。
                if !self.refinerActive {
                    self.finishFinal(rawText: text, final: self.corrected(text))
                    return
                }
                // 没识别到内容(空点一下)→ 不润色、不显示,静默收掉(不出现「已插入」「AI 润色中」)。
                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    self.finalizeFallbackWork?.cancel(); self.finalizeFallbackWork = nil
                    self.hudModel.reset()
                    self.hideHUD(after: 0)
                    return
                }
                // 润色开(云端/本地):先备好规则版(超时回退 / 「立即插入」用),HUD 进「润色中」,
                // 异步等润色返回再替换插入。Refiner 内部超时/护栏不过会安全回退规则版,绝不卡死或丢字。
                let rule = self.corrected(text)
                self.pendingPolishRaw = text
                self.pendingPolishRule = rule
                self.hudModel.partialText = self.corrected(text, isFinal: false)
                if self.store.insertMethod != "type" {     // 仅 paste 模式有 HUD
                    self.hudModel.phase = .polishing
                    self.armPolishSlow()
                }
                self.polishTask?.cancel()
                self.polishTask = Task { @MainActor [weak self] in
                    guard let self else { return }
                    let final = await self.correctedFinalAsync(text)
                    if Task.isCancelled { return }
                    self.finalizePolish(final: final)
                }
            }
        }

        hudModel.reset()
        hudModel.phase = .empty
        hudModel.elapsed = "0:00"
        sessionStart = Date()
        startElapsedTimer()
        // 逐字 (streaming) mode types straight into the focused app — no overlay (the
        // 60fps HUD competed for the main thread and could drop keystrokes). The
        // one-shot "paste" mode still shows the HUD so you can preview before release.
        if store.insertMethod != "type" { showHUD() }
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
        guard !onboardingActive, !inTry, !onCallActive else { return }
        guard engineReady else { return }
        mic.stop()
        stopElapsedTimer()
        setStatusIcon("✍️")
        hudModel.phase = .finalizing

        // endSession() finalizes the utterance and fires onFinal on the main queue,
        // which performs the insert (streamed or one-shot paste) AND records history.
        // Do NOT read a buffer synchronously here — onFinal hasn't run yet (that race
        // was the "shows text but never inserts / history empty" bug).
        engine?.endSession()
        if store.cueEnabled { CueSound.shared.play(theme: store.cueTheme, start: false) }
        // 润色开(paste):释放后异步等大模型 —— onFinal 会把 HUD 切到 .polishing、润色完成再 .done。
        // 这里不能立刻 .done/隐藏,否则 HUD 早早消失而文本几秒后才真正插入。
        if refinerActive && store.insertMethod != "type" {
            if hudModel.partialText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // 空点一下、没识别到任何内容 → 不显示任何收尾态(「已插入」「AI 润色中」都不要),
                // 同步置 idle 避免闪屏,然后直接收掉面板。
                hudModel.reset()
                hideHUD(after: 0)
            } else {
                // 说了话才进「润色中」(转圈);等润色返回再插入。
                hudModel.phase = .polishing
                // 兜底:万一 onFinal 不触发,0.7s 后若仍在 .polishing 且没真正启动润色 → 静默收掉。
                finalizeFallbackWork?.cancel()
                let fb = DispatchWorkItem { [weak self] in
                    guard let self, self.hudModel.phase == .polishing, self.pendingPolishRaw == nil else { return }
                    self.hideHUD(after: 0)
                }
                finalizeFallbackWork = fb
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: fb)
            }
        } else {
            hudModel.phase = .done
            hideHUD(after: 0.8)
        }
        setStatusIcon(engineReady ? "🎙" : "⏳")
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
        guard engineReady else { return }
        if store.insertMethod == "oncall" { startOnCall() } else { stopOnCall() }
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
    }

    // MARK: launch at login

    /// Reconcile the macOS login item with the stored preference (macOS 13+
    /// SMAppService). Best-effort: failures are logged, not fatal.
    private func applyLaunchAtLogin() {
        LaunchAtLogin.setEnabled(store.launchAtLogin)
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
    func setHotkey(keyCode: Int, modifierOnly: Bool) {
        store.setHotkey(keyCode: keyCode, modifierOnly: modifierOnly)
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
            CloudConfigDTO(enabled: store.cloudEnabled, provider: store.cloudProvider,
                           baseURL: store.cloudBaseURL, model: store.cloudModel,
                           numbers: store.cloudModNumbers, fillers: store.cloudModFillers,
                           restate: store.cloudModRestate, hotwords: store.cloudModHotwords,
                           apiKey: store.cloudApiKey, templatesJSON: store.cloudTemplatesJSON,
                           activeTemplate: store.cloudActiveTemplate, autoOverride: store.cloudAutoOverride,
                           customProvidersJSON: store.cloudCustomProvidersJSON,
                           temperature: store.cloudTemperature, maxTokens: store.cloudMaxTokens,
                           logEnabled: store.cloudLogEnabled, profilesJSON: store.cloudProfilesJSON)
        }
        set {
            store.cloudProvider = newValue.provider; store.cloudBaseURL = newValue.baseURL
            store.cloudModel = newValue.model
            store.cloudModNumbers = newValue.numbers; store.cloudModFillers = newValue.fillers
            store.cloudModRestate = newValue.restate; store.cloudModHotwords = newValue.hotwords
            store.cloudApiKey = newValue.apiKey; store.cloudTemplatesJSON = newValue.templatesJSON
            store.cloudActiveTemplate = newValue.activeTemplate; store.cloudAutoOverride = newValue.autoOverride
            store.cloudCustomProvidersJSON = newValue.customProvidersJSON
            store.cloudTemperature = newValue.temperature; store.cloudMaxTokens = newValue.maxTokens
            store.cloudLogEnabled = newValue.logEnabled
            store.cloudProfilesJSON = newValue.profilesJSON
            store.cloudEnabled = newValue.enabled   // 最后置 enabled,触发一次 refreshRefiner
        }
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
        store.didCompleteOnboarding = true
        closeOnboarding()
    }
}
