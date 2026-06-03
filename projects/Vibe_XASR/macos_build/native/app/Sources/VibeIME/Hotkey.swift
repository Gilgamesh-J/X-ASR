import AppKit
import CoreGraphics
import VibeUI

/// Global push-to-talk via a CGEventTap. The watched key comes from the store;
/// the default is Right Command (keycode 54), a modifier that does nothing on
/// its own, so holding it to talk is side-effect free.
///
/// Two flavours, chosen by `modifierOnly`:
///   * Modifier keys (R/L ⌘⌥⌃⇧) → watch `flagsChanged`; pressed/released is read
///     from the matching CGEventFlags mask (`.maskCommand`, etc.).
///   * Non-modifier keys (F5, Space, letters…) → watch `keyDown`/`keyUp`, gated
///     by keycode (autorepeat keyDowns are coalesced into a single press).
///
/// Call `stop()` then re-create + `start()` to apply a new keycode live.
/// Requires Accessibility / Input-Monitoring permission (harmless if denied —
/// `start()` just returns false).
final class Hotkey {
    var onDown: (() -> Void)?
    var onUp: (() -> Void)?

    private let keycode: CGKeyCode
    private let modifierOnly: Bool
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var down = false

    init(keycode: CGKeyCode = 54, modifierOnly: Bool = true) {
        self.keycode = keycode
        self.modifierOnly = modifierOnly
    }

    /// Convenience: build from the store's current selection.
    @MainActor
    convenience init(store: SettingsStore) {
        self.init(keycode: CGKeyCode(store.hotkeyKeyCode),
                  modifierOnly: store.hotkeyModifierOnly)
    }

    @discardableResult
    func start() -> Bool {
        // Modifier keys arrive as flagsChanged; ordinary keys as keyDown/keyUp.
        let mask: CGEventMask = modifierOnly
            ? CGEventMask(1 << CGEventType.flagsChanged.rawValue)
            : CGEventMask((1 << CGEventType.keyDown.rawValue) |
                          (1 << CGEventType.keyUp.rawValue))

        let cb: CGEventTapCallBack = { _, type, event, refcon in
            let me = Unmanaged<Hotkey>.fromOpaque(refcon!).takeUnretainedValue()
            me.handle(type, event)
            return Unmanaged.passUnretained(event)
        }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
            eventsOfInterest: mask, callback: cb,
            userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        self.tap = tap
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
        self.runLoopSource = src
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    /// Tear down the tap so a new keycode can be installed. If a press was in
    /// flight, deliver the matching up so callers are not left "stuck down".
    func stop() {
        if down { down = false; onUp?() }
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let src = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), src, .commonModes)
        }
        tap = nil
        runLoopSource = nil
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }

        let code = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))

        if modifierOnly {
            guard type == .flagsChanged, code == keycode else { return }
            // Read the flag bit for whichever modifier this keycode is.
            let pressed = event.flags.contains(Hotkey.flagMask(for: keycode))
            if pressed && !down { down = true; onDown?() }
            else if !pressed && down { down = false; onUp?() }
        } else {
            guard code == keycode else { return }
            if type == .keyDown {
                // Coalesce autorepeat keyDowns into a single press.
                if !down { down = true; onDown?() }
            } else if type == .keyUp {
                if down { down = false; onUp?() }
            }
        }
    }

    /// Map a modifier keycode to the CGEventFlags bit that reports its state.
    /// (CGEventFlags do not distinguish left/right, so e.g. both ⌘ keys map to
    /// `.maskCommand` — which is fine: we already gated on the exact keycode.)
    private static func flagMask(for keycode: CGKeyCode) -> CGEventFlags {
        switch Int(keycode) {
        case 54, 55: return .maskCommand
        case 58, 61: return .maskAlternate
        case 59, 62: return .maskControl
        case 56, 60: return .maskShift
        default:     return .maskCommand
        }
    }

    /// Friendly display name for a keycode (delegates to the shared table).
    static func keycodeName(_ code: Int) -> String { VibeKeycodes.name(code) }
}
