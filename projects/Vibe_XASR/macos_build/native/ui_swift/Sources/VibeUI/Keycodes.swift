// ============================================================
//  Vibe XASR — Virtual keycode helpers
//  Pure mapping logic shared by the Settings key-recorder, the onboarding
//  hotkey step and the host app's Hotkey listener. No AppKit/Carbon state —
//  just the friendly-name table and the modifier-key classification.
//
//  Keycodes are macOS virtual keycodes (the same `kVK_*` values CGEvent and
//  NSEvent.keyCode report).
// ============================================================

import Foundation

public enum VibeKeycodes {

    /// Virtual keycodes that are *modifier* keys (Command/Option/Control/Shift,
    /// left + right). These are watched via flagsChanged rather than keyDown.
    /// 54/55 = R/L ⌘, 58/61 = L/R ⌥, 59/62 = L/R ⌃, 56/60 = L/R ⇧.
    public static let modifierKeyCodes: Set<Int> = [54, 55, 56, 58, 59, 60, 61, 62]

    /// Is this virtual keycode a modifier key?
    public static func isModifier(_ keyCode: Int) -> Bool {
        modifierKeyCodes.contains(keyCode)
    }

    /// Friendly display name for a virtual keycode (e.g. 54 → "Right ⌘",
    /// 96 → "F5", 49 → "Space"). Falls back to "Key \(code)".
    public static func name(_ keyCode: Int) -> String {
        if let n = table[keyCode] { return n }
        return "Key \(keyCode)"
    }

    /// The canonical lookup table. Kept deliberately small but covers the keys
    /// the recorder is most likely to capture plus all the modifier variants
    /// the spec calls out.
    private static let table: [Int: String] = [
        // Modifiers (left/right)
        54: "Right ⌘", 55: "Left ⌘",
        58: "Left ⌥",  61: "Right ⌥",
        59: "Left ⌃",  62: "Right ⌃",
        56: "Left ⇧",  60: "Right ⇧",
        63: "Fn",

        // Whitespace / editing
        49: "Space", 48: "Tab", 36: "Return", 76: "Enter", 53: "Esc",
        51: "Delete", 117: "Fwd Delete", 71: "Clear",

        // Arrows
        123: "←", 124: "→", 125: "↓", 126: "↑",

        // Navigation
        115: "Home", 119: "End", 116: "Page Up", 121: "Page Down",
        114: "Help",

        // Function keys
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
        105: "F13", 107: "F14", 113: "F15", 106: "F16", 64: "F17",
        79: "F18", 80: "F19", 90: "F20",

        // Letters (US ANSI)
        0: "A", 11: "B", 8: "C", 2: "D", 14: "E", 3: "F", 5: "G", 4: "H",
        34: "I", 38: "J", 40: "K", 37: "L", 46: "M", 45: "N", 31: "O",
        35: "P", 12: "Q", 15: "R", 1: "S", 17: "T", 32: "U", 9: "V",
        13: "W", 7: "X", 16: "Y", 6: "Z",

        // Number row
        29: "0", 18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6",
        26: "7", 28: "8", 25: "9",

        // Punctuation
        50: "`", 27: "-", 24: "=", 33: "[", 30: "]", 42: "\\",
        41: ";", 39: "'", 43: ",", 47: ".", 44: "/",
    ]
}
