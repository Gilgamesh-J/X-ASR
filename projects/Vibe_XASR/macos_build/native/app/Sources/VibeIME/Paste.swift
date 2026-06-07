import AppKit
import CoreGraphics

/// 简体 → 繁体(字形级,走系统 ICU transform;非台湾词汇级)。供「输出转繁体」开关使用。
enum Hant {
    static func s2t(_ s: String) -> String {
        guard !s.isEmpty else { return s }
        let m = NSMutableString(string: s)
        CFStringTransform(m, nil, "Simplified-Traditional" as CFString, false)
        return m as String
    }
}

/// Inserts text into the focused app via clipboard + ⌘V (reliable for CJK),
/// restoring the previous clipboard. Requires Accessibility permission.
enum Paste {
    static func insert(_ text: String, restore: Bool = true, restoreDelay: TimeInterval = 0.5) {
        guard !text.isEmpty else { return }
        let pb = NSPasteboard.general
        // Snapshot the WHOLE pasteboard (every item + every type: images, files, RTF,
        // not just plain text) so dictation never clobbers what the user had copied.
        let saved = restore ? snapshotPasteboard() : []
        pb.clearContents()
        pb.setString(text, forType: .string)
        usleep(20_000)            // let the target app observe the new pasteboard
        sendCmdV()
        if restore {
            DispatchQueue.global().asyncAfter(deadline: .now() + restoreDelay) {
                restorePasteboard(saved)
            }
        }
    }

    /// Deep-copy the current pasteboard's items (so they can be re-written later).
    /// NSPasteboardItem read back from the board can't be re-added, so we clone each.
    private static func snapshotPasteboard() -> [NSPasteboardItem] {
        guard let items = NSPasteboard.general.pasteboardItems else { return [] }
        return items.map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }
    }

    /// Restore a previously captured snapshot. Empty snapshot → leave the board
    /// cleared (the user's clipboard was empty before; don't keep the dictation text).
    private static func restorePasteboard(_ items: [NSPasteboardItem]) {
        let pb = NSPasteboard.general
        pb.clearContents()
        if !items.isEmpty { pb.writeObjects(items) }
    }

    /// Overwrite the clipboard with `text` and leave it there (for the "overwrite
    /// clipboard after each dictation" option — handy to paste anywhere later).
    static func setClipboard(_ text: String) {
        guard !text.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    /// Type the text out as synthesized Unicode keystrokes (no clipboard). More
    /// compatible with apps that block programmatic paste, at the cost of speed.
    /// Posts the whole string in one keyDown via CGEventKeyboardSetUnicodeString.
    static func typeOut(_ text: String) {
        guard !text.isEmpty else { return }
        let src = CGEventSource(stateID: .hidSystemState)
        // Chunk to keep each event's UTF-16 payload modest (some apps drop very
        // large unicode strings in a single event).
        let scalars = Array(text.utf16)
        let chunk = 20
        var i = 0
        while i < scalars.count {
            let slice = Array(scalars[i..<min(i + chunk, scalars.count)])
            if let down = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true),
               let up = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false) {
                slice.withUnsafeBufferPointer { buf in
                    down.keyboardSetUnicodeString(stringLength: buf.count, unicodeString: buf.baseAddress)
                    up.keyboardSetUnicodeString(stringLength: buf.count, unicodeString: buf.baseAddress)
                }
                down.post(tap: .cghidEventTap)
                up.post(tap: .cghidEventTap)
            }
            i += chunk
            usleep(1_500)
        }
    }

    /// Send `n` delete (backspace) keystrokes — used by streaming insertion to
    /// retract the diverged tail of a revised partial before retyping it.
    static func backspace(_ n: Int) {
        guard n > 0 else { return }
        let src = CGEventSource(stateID: .hidSystemState)
        let kDelete: CGKeyCode = 51
        for _ in 0..<n {
            CGEvent(keyboardEventSource: src, virtualKey: kDelete, keyDown: true)?.post(tap: .cghidEventTap)
            CGEvent(keyboardEventSource: src, virtualKey: kDelete, keyDown: false)?.post(tap: .cghidEventTap)
        }
    }

    private static func sendCmdV() {
        let src = CGEventSource(stateID: .hidSystemState)
        let kV: CGKeyCode = 9
        let down = CGEvent(keyboardEventSource: src, virtualKey: kV, keyDown: true)
        down?.flags = .maskCommand
        let up = CGEvent(keyboardEventSource: src, virtualKey: kV, keyDown: false)
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}

/// Robust streaming insertion via synthesized Unicode keystrokes.
///
/// The old approach (one event carrying a 20-char UTF-16 chunk) was unreliable —
/// target apps coalesce/drop multi-character synthetic events, so only part of the
/// recognized text landed. This posts ONE character per key event on a dedicated
/// serial queue with a small inter-event delay, and tracks what has actually been
/// typed (`committed`, mutated only on the queue) so each partial diffs against the
/// real on-screen state: backspace the diverged tail, type the new tail. Converges
/// to the final text even when partials revise.
final class StreamingInserter {
    private let q = DispatchQueue(label: "com.xasr.vibexasr.inserter")
    private let src = CGEventSource(stateID: .hidSystemState)
    private let charDelay: useconds_t = 11_000   // 11 ms between events (reliability > speed)
    private var committed: [Character] = []      // touched only on `q`

    /// Make the focused app's text match `text` (diff vs already-typed).
    func update(_ text: String) {
        let target = Array(text)
        q.async { [weak self] in
            guard let self else { return }
            var common = 0
            let cap = min(self.committed.count, target.count)
            while common < cap && self.committed[common] == target[common] { common += 1 }
            let del = self.committed.count - common
            if del > 0 { self.postBackspaces(del) }
            if common < target.count { self.postChars(Array(target[common...])) }
            self.committed = target
        }
    }

    /// Forget the typed-state (call at the start of each hold).
    func reset() {
        q.async { [weak self] in self?.committed = [] }
    }

    // CRITICAL: clear modifier flags on every synthesized event. Push-to-talk holds
    // a modifier hotkey (e.g. Right ⌘); without this, each char becomes ⌘+char (a
    // shortcut the app eats) instead of text — the "only part inserted" bug. Setting
    // flags=[] makes the unicode payload land as plain insertText regardless of what
    // modifier is physically held.
    private func postBackspaces(_ n: Int) {
        for _ in 0..<n {
            if let d = CGEvent(keyboardEventSource: src, virtualKey: 51, keyDown: true) {
                d.flags = []; d.post(tap: .cghidEventTap)
            }
            if let u = CGEvent(keyboardEventSource: src, virtualKey: 51, keyDown: false) {
                u.flags = []; u.post(tap: .cghidEventTap)
            }
            usleep(charDelay)
        }
    }

    private func postChars(_ chars: [Character]) {
        for ch in chars {
            let u16 = Array(String(ch).utf16)
            if let down = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true) {
                u16.withUnsafeBufferPointer { down.keyboardSetUnicodeString(stringLength: $0.count, unicodeString: $0.baseAddress) }
                down.flags = []
                down.post(tap: .cghidEventTap)
            }
            if let up = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false) {
                u16.withUnsafeBufferPointer { up.keyboardSetUnicodeString(stringLength: $0.count, unicodeString: $0.baseAddress) }
                up.flags = []
                up.post(tap: .cghidEventTap)
            }
            usleep(charDelay)
        }
    }
}
