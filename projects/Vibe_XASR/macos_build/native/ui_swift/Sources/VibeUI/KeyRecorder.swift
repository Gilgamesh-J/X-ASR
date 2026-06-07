// ============================================================
//  Vibe XASR — Hotkey recorder
//  A button that, while "recording", captures the next key via local + global
//  NSEvent monitors and reports (keyCode, isModifier). Shows the friendly key
//  name from VibeKeycodes. Used both in Settings → Dictation and in the
//  onboarding "choose hotkey" step.
//
//  The host app persists the captured value (SettingsStore) and restarts its
//  global Hotkey listener; this view only does capture + display.
// ============================================================

import SwiftUI
import AppKit

/// Captures a single key press (key-down for ordinary keys, a fresh modifier
/// for modifier-only keys). Lives as an `ObservableObject` so SwiftUI can react
/// to the "recording" flag and the host can drive it imperatively if needed.
@MainActor
public final class KeyCaptureController: ObservableObject {
    @Published public private(set) var recording = false

    private var localMonitor: Any?
    private var globalMonitor: Any?
    /// Called on the main thread with the captured (keyCode, isModifier).
    private var onCapture: ((Int, Bool) -> Void)?

    public init() {}

    /// Begin capturing. `completion` fires once with the captured key, then
    /// recording stops automatically.
    public func begin(completion: @escaping (Int, Bool) -> Void) {
        guard !recording else { return }
        onCapture = completion
        recording = true

        // Local monitor: captures events while our app is key. Returning nil
        // swallows the event so the recorded key does not also act on the UI.
        localMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .flagsChanged]
        ) { [weak self] event in
            self?.process(event)
            return nil
        }
        // Global monitor: captures even when another app is frontmost (handy
        // during onboarding before the window grabs focus). Read-only.
        globalMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.keyDown, .flagsChanged]
        ) { [weak self] event in
            self?.process(event)
        }
    }

    /// 组合键捕获(单键或修饰+键,如 1 / ⌥1 / ⌘⇧S)。只看 keyDown,带当前修饰位;Esc 取消。
    private var onCaptureCombo: ((Int, HotkeyMods) -> Void)?
    public func beginCombo(completion: @escaping (Int, HotkeyMods) -> Void) {
        guard !recording else { return }
        onCaptureCombo = completion
        recording = true
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            self?.processCombo(event); return nil
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            self?.processCombo(event)
        }
    }
    private func processCombo(_ event: NSEvent) {
        let code = Int(event.keyCode)
        if code == 53 { finish(); return }   // Esc 取消
        let mods = HotkeyMods(event.modifierFlags)
        let cb = onCaptureCombo
        finish()
        cb?(code, mods)
    }

    /// 通用捕获:纯修饰键(flagsChanged)或 单键/组合键(keyDown + 当前修饰位)。Esc 取消。
    /// 用于主听写键(既可选 Right ⌘ 这类纯修饰,也可选 F5 / ⌥1 这类组合)。
    ///
    /// 关键:修饰键「按下」不能立刻判定为纯修饰键——否则永远录不出 ⌥1 这类组合
    /// (按 ⌥ 的瞬间就结束了)。改为:记住按下的修饰键作为候选;若随后按下一个
    /// 非修饰键 → 录成组合;若该修饰键先被「松开」且期间没按别的键 → 才录成纯修饰键。
    /// 通用捕获状态:
    ///   * anyHeldCodes —— 录制期间按下过的修饰键 keycode(有序,首个=主修饰,区分左右);
    ///   * anyPeakFlags —— 这些修饰键叠加的峰值标志位(用于定型组合)。
    /// 修饰键「按下」只记入候选;按下普通键→组合(修饰+键),松开任一修饰键→定型为
    /// 纯单修饰键(1 个)或修饰键组合(≥2 个,如 Right ⌘ + ⌥)。
    private var onCaptureAny: ((Int, Bool, HotkeyMods) -> Void)?
    private var anyHeldCodes: [Int] = []
    private var anyPeakFlags: HotkeyMods = []
    public func beginAny(completion: @escaping (Int, Bool, HotkeyMods) -> Void) {
        guard !recording else { return }
        onCaptureAny = completion
        anyHeldCodes = []
        anyPeakFlags = []
        recording = true
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] e in
            self?.processAny(e); return nil
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] e in
            self?.processAny(e)
        }
    }
    private func processAny(_ event: NSEvent) {
        let code = Int(event.keyCode)
        switch event.type {
        case .keyDown:
            if code == 53 { finish(); return }   // Esc
            let mods = HotkeyMods(event.modifierFlags)
            let cb = onCaptureAny; finish(); cb?(code, false, mods)   // 单键 / 修饰+普通键
        case .flagsChanged:
            guard VibeKeycodes.isModifier(code) else { break }
            if Self.modifierPressed(event, code: code) {
                // 修饰键按下:计入候选集合 + 累加峰值标志位。
                if !anyHeldCodes.contains(code) { anyHeldCodes.append(code) }
                anyPeakFlags.formUnion(HotkeyMods(event.modifierFlags))
            } else if let primary = anyHeldCodes.first {
                // 任一修饰键松开 → 用峰值定型(主修饰=首个按下,区分左右)。
                let cb = onCaptureAny
                let peak = anyPeakFlags
                let count = anyHeldCodes.count
                finish()
                if count >= 2 {
                    cb?(primary, true, peak.subtracting(VibeKeycodes.flagFor(primary)))  // 修饰键组合
                } else {
                    cb?(primary, true, [])                                                // 纯单修饰键
                }
            }
        default: break
        }
    }

    public func cancel() {
        finish()
    }

    private func process(_ event: NSEvent) {
        let code = Int(event.keyCode)
        switch event.type {
        case .keyDown:
            // Ordinary key. Esc cancels without recording.
            if code == 53 { finish(); return }
            deliver(code: code, isModifier: false)
        case .flagsChanged:
            // Only fire on a *press* (a modifier flag now set for this key),
            // not on release. If no relevant flag is set, ignore.
            if VibeKeycodes.isModifier(code), Self.modifierPressed(event, code: code) {
                deliver(code: code, isModifier: true)
            }
        default:
            break
        }
    }

    private func deliver(code: Int, isModifier: Bool) {
        let cb = onCapture
        finish()
        cb?(code, isModifier)
    }

    private func finish() {
        if let m = localMonitor { NSEvent.removeMonitor(m); localMonitor = nil }
        if let m = globalMonitor { NSEvent.removeMonitor(m); globalMonitor = nil }
        onCapture = nil
        onCaptureCombo = nil
        onCaptureAny = nil
        anyHeldCodes = []
        anyPeakFlags = []
        recording = false
    }

    /// Is the modifier identified by `code` currently in the *pressed* state?
    private static func modifierPressed(_ event: NSEvent, code: Int) -> Bool {
        let f = event.modifierFlags
        switch code {
        case 54, 55: return f.contains(.command)
        case 58, 61: return f.contains(.option)
        case 59, 62: return f.contains(.control)
        case 56, 60: return f.contains(.shift)
        case 63:     return f.contains(.function)
        default:     return false
        }
    }
    // Monitors are torn down in finish() (on capture or cancel). The recorder
    // view drives begin()/cancel() over its lifetime, so no nonisolated deinit
    // cleanup is needed (and Swift 6 forbids touching main-actor state there).
}

/// The recorder control: shows the current key name, and while recording shows
/// "按下按键…". Binds to a `keyCode`/`isModifier` pair; on capture it updates
/// them and calls `onChange` so the host can persist + restart the listener.
public struct HotkeyRecorder: View {
    @Environment(\.colorScheme) private var scheme
    @StateObject private var capture = KeyCaptureController()

    @Binding var keyCode: Int
    @Binding var isModifier: Bool
    var onChange: ((Int, Bool) -> Void)?

    public init(keyCode: Binding<Int>,
                isModifier: Binding<Bool>,
                onChange: ((Int, Bool) -> Void)? = nil) {
        self._keyCode = keyCode
        self._isModifier = isModifier
        self.onChange = onChange
    }

    public var body: some View {
        Button {
            if capture.recording {
                capture.cancel()
            } else {
                capture.begin { code, mod in
                    keyCode = code
                    isModifier = mod
                    onChange?(code, mod)
                }
            }
        } label: {
            Group {
                if capture.recording {
                    Text("按下按键…").foregroundStyle(Vibe.Palette.accentB)
                } else {
                    Text(VibeKeycodes.name(keyCode))
                        .font(Vibe.Fonts.mono(12.5))
                        .foregroundStyle(Vibe.Palette.text(scheme))
                }
            }
            .font(Vibe.Fonts.ui(12.5))
            .padding(.vertical, 7).padding(.horizontal, 14)
            .frame(minWidth: 92)
            .background(
                RoundedRectangle(cornerRadius: Vibe.Radius.control, style: .continuous)
                    .fill(Vibe.Palette.surface2(scheme))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Vibe.Radius.control, style: .continuous)
                    .strokeBorder(capture.recording ? Vibe.Palette.accentA
                                                     : Vibe.Palette.hairline(scheme),
                                  lineWidth: capture.recording ? 1.5 : 1)
            )
            .shadow(color: capture.recording ? Vibe.Palette.accentA.opacity(0.2) : .clear,
                    radius: capture.recording ? 4 : 0)
        }
        .buttonStyle(.plain)
    }
}

extension HotkeyMods {
    /// 从 AppKit 修饰位构造。
    public init(_ f: NSEvent.ModifierFlags) {
        var m = HotkeyMods()
        if f.contains(.command) { m.insert(.command) }
        if f.contains(.option)  { m.insert(.option) }
        if f.contains(.control) { m.insert(.control) }
        if f.contains(.shift)   { m.insert(.shift) }
        self = m
    }
}

/// 组合键录制控件:点一下进入录制,按下「单键或修饰+键」即捕获并回调 (keyCode, mods)。
/// 用于「提示词工作室」给模板绑定快捷键。
public struct ComboRecorder: View {
    @Environment(\.colorScheme) private var scheme
    @StateObject private var capture = KeyCaptureController()
    var display: String          // 当前绑定显示名(空 = 未设置)
    var placeholder: String      // 未设置时占位
    var onCapture: (Int, HotkeyMods) -> Void
    public init(display: String, placeholder: String, onCapture: @escaping (Int, HotkeyMods) -> Void) {
        self.display = display; self.placeholder = placeholder; self.onCapture = onCapture
    }
    public var body: some View {
        Button {
            if capture.recording { capture.cancel() }
            else { capture.beginCombo { code, mods in onCapture(code, mods) } }
        } label: {
            Text(capture.recording ? "按下快捷键…" : (display.isEmpty ? placeholder : display))
                .font(Vibe.Fonts.mono(11.5))
                .foregroundStyle(capture.recording ? Vibe.Palette.accentB
                                 : (display.isEmpty ? Vibe.Palette.textMuted(scheme) : Vibe.Palette.text(scheme)))
                .padding(.vertical, 5).padding(.horizontal, 10)
                .background(RoundedRectangle(cornerRadius: 7).fill(Vibe.Palette.surface2(scheme))
                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(capture.recording ? Vibe.Palette.accentA : Vibe.Palette.hairline(scheme), lineWidth: capture.recording ? 1.5 : 1)))
        }
        .buttonStyle(.plain)
    }
}

/// 主听写键录制控件:支持「纯修饰键(Right ⌘)/ 单键(F5)/ 组合(⌥1)」三种。
/// 写回 keyCode + modifierOnly + mods(rawValue),并回调宿主持久化 + 重建监听。
public struct GlobalHotkeyRecorder: View {
    @Environment(\.colorScheme) private var scheme
    @StateObject private var capture = KeyCaptureController()
    @Binding var keyCode: Int
    @Binding var modifierOnly: Bool
    @Binding var mods: Int
    var onChange: (Int, Bool, HotkeyMods) -> Void
    public init(keyCode: Binding<Int>, modifierOnly: Binding<Bool>, mods: Binding<Int>,
                onChange: @escaping (Int, Bool, HotkeyMods) -> Void) {
        self._keyCode = keyCode; self._modifierOnly = modifierOnly; self._mods = mods; self.onChange = onChange
    }
    private var display: String {
        VibeKeycodes.displayName(keyCode: keyCode, modifierOnly: modifierOnly,
                                 mods: HotkeyMods(rawValue: mods))
    }
    public var body: some View {
        Button {
            if capture.recording { capture.cancel() }
            else {
                capture.beginAny { code, isMod, m in
                    keyCode = code; modifierOnly = isMod; mods = m.rawValue
                    onChange(code, isMod, m)
                }
            }
        } label: {
            Group {
                if capture.recording {
                    Text("按下按键 / 组合…").foregroundStyle(Vibe.Palette.accentB)
                } else {
                    Text(display).font(Vibe.Fonts.mono(12.5)).foregroundStyle(Vibe.Palette.text(scheme))
                }
            }
            .font(Vibe.Fonts.ui(12.5))
            .padding(.vertical, 7).padding(.horizontal, 14)
            .frame(minWidth: 92)
            .background(RoundedRectangle(cornerRadius: Vibe.Radius.control, style: .continuous).fill(Vibe.Palette.surface2(scheme)))
            .overlay(RoundedRectangle(cornerRadius: Vibe.Radius.control, style: .continuous)
                .strokeBorder(capture.recording ? Vibe.Palette.accentA : Vibe.Palette.hairline(scheme), lineWidth: capture.recording ? 1.5 : 1))
        }
        .buttonStyle(.plain)
    }
}
