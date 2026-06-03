import Foundation

/// Post-recognition text replacement ("corrections"). Solves what contextual
/// biasing (hotwords) cannot: coined / brand spellings the model can't emit (it
/// hears "open claw", you want "OpenClaw") and stubborn homophones the acoustic
/// model won't flip ("李牧" → "李沐"). Each rule is `from => to`; applied to the
/// final (and streaming) recognized text right before it reaches the screen.
enum Replacements {
    struct Rule { let from: String; let to: String }

    /// Parse "from => to" (also accepts "->") lines; skips blanks and `#` comments.
    static func parse(_ text: String) -> [Rule] {
        text.split(whereSeparator: \.isNewline).compactMap { raw -> Rule? in
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { return nil }
            guard let sep = line.range(of: "=>") ?? line.range(of: "->") else { return nil }
            let from = line[..<sep.lowerBound].trimmingCharacters(in: .whitespaces)
            let to = line[sep.upperBound...].trimmingCharacters(in: .whitespaces)
            guard !from.isEmpty else { return nil }
            return Rule(from: from, to: to)
        }
    }

    /// Number of valid rules in the raw text (for the UI counter).
    static func count(_ text: String) -> Int { parse(text).count }

    /// Apply rules to `text` in a SINGLE left-to-right pass: all `from` patterns are
    /// matched simultaneously (longest first), so a rule's replacement is never
    /// re-matched by a later rule. (Sequential replaces caused cascades like
    /// "a penclaw" → "OpenClaw" → "OOpenClaw".) Case-insensitive; CJK unaffected.
    static func apply(_ text: String, _ rules: [Rule]) -> String {
        let sorted = rules.filter { !$0.from.isEmpty }.sorted { $0.from.count > $1.from.count }
        guard !sorted.isEmpty else { return text }
        let pattern = sorted.map { NSRegularExpression.escapedPattern(for: $0.from) }.joined(separator: "|")
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return text }
        let ns = text as NSString
        var out = ""
        var last = 0
        re.enumerateMatches(in: text, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
            guard let r = m?.range else { return }
            out += ns.substring(with: NSRange(location: last, length: r.location - last))
            let hit = ns.substring(with: r)
            // longest-first means the first rule equal to the matched text is the one
            out += sorted.first { $0.from.compare(hit, options: .caseInsensitive) == .orderedSame }?.to ?? hit
            last = r.location + r.length
        }
        out += ns.substring(from: last)
        return out
    }

    /// Snippet expansion: like `apply`, but tuned for spoken triggers expanding to
    /// (possibly multi-line) text. Two differences from `apply`:
    ///   1. the trigger tolerates whitespace BETWEEN characters, so a spelled-out
    ///      "C C" (this model emits letters spaced) matches a trigger of "cc";
    ///   2. it swallows one trailing sentence-final mark (。.!?!?) after the hit,
    ///      so the expansion lands clean instead of inheriting the auto-period
    ///      `SherpaASR` appends to a finalized utterance. A comma is left intact.
    /// Single left-to-right pass (longest trigger first) so an expansion is never
    /// re-matched by a later snippet.
    static func expand(_ text: String, _ rules: [Rule]) -> String {
        let sorted = rules.filter { !$0.from.isEmpty }.sorted { $0.from.count > $1.from.count }
        guard !sorted.isEmpty else { return text }
        let alts = sorted.map { rule -> String in
            let core = rule.from.map { NSRegularExpression.escapedPattern(for: String($0)) }
                .joined(separator: "\\s*")
            return "(" + core + ")"
        }
        let pattern = "(?:" + alts.joined(separator: "|") + ")\\s*[。.!?！？]?"
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return text }
        let ns = text as NSString
        var out = ""
        var last = 0
        re.enumerateMatches(in: text, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
            guard let m = m else { return }
            let r = m.range
            out += ns.substring(with: NSRange(location: last, length: r.location - last))
            for (i, rule) in sorted.enumerated() where m.range(at: i + 1).location != NSNotFound {
                out += rule.to
                break
            }
            last = r.location + r.length
        }
        out += ns.substring(from: last)
        return out
    }
}
