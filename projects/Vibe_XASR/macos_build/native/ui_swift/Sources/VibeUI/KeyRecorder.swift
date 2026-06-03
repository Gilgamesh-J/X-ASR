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
