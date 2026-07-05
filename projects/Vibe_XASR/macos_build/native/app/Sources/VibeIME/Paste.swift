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
/// typed (`committed`, mutated only on the queue). Updates are applied as the
/// smallest set of local patches we can safely perform with synthetic keys:
/// preserve the common prefix/suffix, compute a minimal edit script inside the
/// changed middle span, then apply each changed hunk independently while always
/// restoring the caret to the end. This avoids deleting a huge middle block when
/// refine only made several small edits in different places.
final class StreamingInserter {
    private let q = DispatchQueue(label: "com.xasr.vibexasr.inserter")
    private let src = CGEventSource(stateID: .hidSystemState)
    private let keyDelay: useconds_t = 5_000
    private var committed: [Character] = []      // touched only on `q`

    /// Make the focused app's text match `text` (diff vs already-typed).
    func update(_ text: String) {
        let target = Array(text)
        q.async { [weak self] in
            guard let self else { return }
            let patch = Self.makePatch(from: self.committed, to: target)
            self.apply(patch)
            self.committed = target
        }
    }

    /// Replace everything after a stable prefix in one shot: select the old tail,
    /// then paste the new tail. Used by local refine window flushes to avoid
    /// over-smart diffing when only the latest chunk window should be rewritten.
    func replaceFromPrefixCount(_ prefixCount: Int, to text: String) {
        let target = Array(text)
        q.async { [weak self] in
            guard let self else { return }
            let keep = min(prefixCount, min(self.committed.count, target.count))
            let oldTailCount = max(self.committed.count - keep, 0)
            let newTail = keep < target.count ? String(target[keep...]) : ""
            self.applyTailReplacement(deleteCount: oldTailCount, insertText: newTail)
            self.committed = target
        }
    }

    /// Forget the typed-state (call at the start of each hold).
    func reset() {
        q.async { [weak self] in self?.committed = [] }
    }

    private struct Hunk {
        let leftMoves: Int
        let deleteCount: Int
        let insertChars: [Character]
        let rightMoves: Int
    }

    private struct Patch {
        let hunks: [Hunk]
    }

    private enum DiffOp {
        case keep
        case delete
        case insert(Character)
    }

    /// Build the smallest practical set of in-place edits. We still trim the
    /// unchanged prefix/suffix first, but inside the changed middle region we use
    /// an LCS-based diff so separated edits become separated hunks instead of one
    /// giant replace.
    private static func makePatch(from old: [Character], to new: [Character]) -> Patch {
        var prefix = 0
        let prefixCap = min(old.count, new.count)
        while prefix < prefixCap && old[prefix] == new[prefix] { prefix += 1 }

        var suffix = 0
        let oldRemain = old.count - prefix
        let newRemain = new.count - prefix
        while suffix < oldRemain && suffix < newRemain &&
              old[old.count - 1 - suffix] == new[new.count - 1 - suffix] {
            suffix += 1
        }

        let oldMiddleEnd = old.count - suffix
        let newMiddleEnd = new.count - suffix
        let oldMiddle = prefix < oldMiddleEnd ? Array(old[prefix..<oldMiddleEnd]) : []
        let newMiddle = prefix < newMiddleEnd ? Array(new[prefix..<newMiddleEnd]) : []
        guard !oldMiddle.isEmpty || !newMiddle.isEmpty else { return Patch(hunks: []) }

        let ops = diffOps(from: oldMiddle, to: newMiddle)
        var hunks: [Hunk] = []
        var oldPos = 0
        var newPos = 0
        var hunkOldStart: Int?
        var hunkNewStart: Int?
        var deleteCount = 0
        var insertChars: [Character] = []

        func flushHunk() {
            guard let oldStart = hunkOldStart, let newStart = hunkNewStart else { return }
            let globalNewEnd = prefix + newPos
            let rightMoves = new.count - globalNewEnd
            _ = oldStart
            _ = newStart
            hunks.append(Hunk(
                leftMoves: rightMoves,
                deleteCount: deleteCount,
                insertChars: insertChars,
                rightMoves: rightMoves
            ))
            hunkOldStart = nil
            hunkNewStart = nil
            deleteCount = 0
            insertChars.removeAll(keepingCapacity: true)
        }

        for op in ops {
            switch op {
            case .keep:
                flushHunk()
                oldPos += 1
                newPos += 1
            case .delete:
                if hunkOldStart == nil {
                    hunkOldStart = oldPos
                    hunkNewStart = newPos
                }
                oldPos += 1
                deleteCount += 1
            case .insert(let ch):
                if hunkOldStart == nil {
                    hunkOldStart = oldPos
                    hunkNewStart = newPos
                }
                newPos += 1
                insertChars.append(ch)
            }
        }
        flushHunk()
        return Patch(hunks: hunks)
    }

    private static func diffOps(from old: [Character], to new: [Character]) -> [DiffOp] {
        let m = old.count
        let n = new.count
        if m == 0 { return new.map(DiffOp.insert) }
        if n == 0 { return Array(repeating: .delete, count: m) }

        var dp = Array(repeating: Array(repeating: 0, count: n + 1), count: m + 1)
        var i = m - 1
        while i >= 0 {
            var j = n - 1
            while j >= 0 {
                if old[i] == new[j] {
                    dp[i][j] = dp[i + 1][j + 1] + 1
                } else {
                    dp[i][j] = max(dp[i + 1][j], dp[i][j + 1])
                }
                j -= 1
            }
            if i == 0 { break }
            i -= 1
        }

        var out: [DiffOp] = []
        var oi = 0
        var nj = 0
        while oi < m && nj < n {
            if old[oi] == new[nj] {
                out.append(.keep)
                oi += 1
                nj += 1
            } else if dp[oi + 1][nj] >= dp[oi][nj + 1] {
                out.append(.delete)
                oi += 1
            } else {
                out.append(.insert(new[nj]))
                nj += 1
            }
        }
        while oi < m {
            out.append(.delete)
            oi += 1
        }
        while nj < n {
            out.append(.insert(new[nj]))
            nj += 1
        }
        return out
    }

    // CRITICAL: clear modifier flags on every synthesized event. Push-to-talk holds
    // a modifier hotkey (e.g. Right ⌘); without this, each char becomes ⌘+char (a
    // shortcut the app eats) instead of text — the "only part inserted" bug. Setting
    // flags=[] makes the unicode payload land as plain insertText regardless of what
    // modifier is physically held.
    private func apply(_ patch: Patch) {
        for hunk in patch.hunks.reversed() {
            if hunk.leftMoves > 0 { postArrow(keyCode: 123, count: hunk.leftMoves) }
            if hunk.deleteCount > 0 { postBackspaces(hunk.deleteCount) }
            if !hunk.insertChars.isEmpty { postChars(hunk.insertChars) }
            if hunk.rightMoves > 0 { postArrow(keyCode: 124, count: hunk.rightMoves) }
        }
    }

    private func applyTailReplacement(deleteCount: Int, insertText: String) {
        guard deleteCount > 0 || !insertText.isEmpty else { return }
        if deleteCount > 0 {
            postArrow(keyCode: 123, count: deleteCount, shift: true)
            usleep(keyDelay * 2)
            postDeleteSelection()
            usleep(keyDelay * 2)
        }
        if !insertText.isEmpty {
            Paste.insert(insertText, restore: true, restoreDelay: 0.2)
            usleep(25_000)
        }
    }

    private func postBackspaces(_ n: Int) {
        for _ in 0..<n {
            if let d = CGEvent(keyboardEventSource: src, virtualKey: 51, keyDown: true) {
                d.flags = []; d.post(tap: .cghidEventTap)
            }
            if let u = CGEvent(keyboardEventSource: src, virtualKey: 51, keyDown: false) {
                u.flags = []; u.post(tap: .cghidEventTap)
            }
            usleep(keyDelay)
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
            usleep(keyDelay)
        }
    }

    private func postArrow(keyCode: CGKeyCode, count: Int) {
        postArrow(keyCode: keyCode, count: count, shift: false)
    }

    private func postArrow(keyCode: CGKeyCode, count: Int, shift: Bool) {
        guard count > 0 else { return }
        for _ in 0..<count {
            if let d = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: true) {
                d.flags = shift ? .maskShift : []
                d.post(tap: .cghidEventTap)
            }
            if let u = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: false) {
                u.flags = shift ? .maskShift : []
                u.post(tap: .cghidEventTap)
            }
            usleep(keyDelay)
        }
    }

    private func postDeleteSelection() {
        if let d = CGEvent(keyboardEventSource: src, virtualKey: 51, keyDown: true) {
            d.flags = []
            d.post(tap: .cghidEventTap)
        }
        if let u = CGEvent(keyboardEventSource: src, virtualKey: 51, keyDown: false) {
            u.flags = []
            u.post(tap: .cghidEventTap)
        }
        usleep(keyDelay)
    }
}
