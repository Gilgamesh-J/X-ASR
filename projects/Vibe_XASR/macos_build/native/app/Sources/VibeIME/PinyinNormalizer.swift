import Foundation

/// Homophone correction by pinyin: rewrite any run of CJK chars that *sounds the
/// same* as a dictionary word into that word's exact spelling. This catches what
/// contextual biasing can't — a proper noun like "贾扬清" that the recognizer
/// scatters across same-sounding chars (贾阳清 / 嘉阳清 / 贾杨青 / 贾央青 …). All
/// share the toneless pinyin "jia yang qing", so they normalize to the one
/// spelling the user put in their dictionary.
///
/// Matching is per-character, multi-reading (uses the char's full pinyin set so
/// heteronyms still match), longest dictionary word first. Only the user's CJK
/// dictionary words drive it, so the scope is exactly what they opted into.
@MainActor
final class PinyinNormalizer {
    static let shared = PinyinNormalizer()

    /// char → set of toneless readings (e.g. 沈 → {shen, chen, tan}).
    private var table: [Character: Set<String>] = [:]
    private var loaded = false

    /// Dictionary words (CJK only), longest first, with each word's per-char
    /// reading sets precomputed.
    private var words: [(word: [Character], reads: [Set<String>])] = []

    private init() {}

    /// Load the bundled 汉字→拼音 table once. No-op (and normalizer stays inert)
    /// when the table is missing.
    func loadTableIfNeeded(path: String?) {
        guard !loaded, let path, let text = try? String(contentsOfFile: path, encoding: .utf8) else { return }
        var t: [Character: Set<String>] = [:]
        t.reserveCapacity(28000)
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ")
            guard let first = parts.first, let ch = first.first else { continue }
            t[ch] = Set(parts.dropFirst().map(String.init))
        }
        table = t
        loaded = true
    }

    /// Minimum length for a word to drive pinyin normalization. Single chars (and
    /// the empty case) are NEVER allowed — a 1-char homophone rule would rewrite
    /// every same-sounding char in any text (e.g. "沐" would eat 木/目/牧…). 2 is the
    /// floor (2-char names are common); longer is safer still.
    private let minLen = 2

    /// Set the active dictionary words. Only multi-char, all-CJK words are used —
    /// English words and single chars are skipped. Empty list disables it.
    func setWords(_ raw: [String]) {
        words = preparedWords(raw)
    }

    /// One-shot normalization against a temporary word list. Used for the final
    /// hotword pass so scenario defaults + custom words can still apply even when
    /// the live pinyin toggle is off.
    func normalize(_ text: String, withRawWords raw: [String]) -> String {
        normalize(text, prepared: preparedWords(raw))
    }

    private func preparedWords(_ raw: [String]) -> [(word: [Character], reads: [Set<String>])] {
        raw
            .map { Array($0) }
            .filter { chars in chars.count >= minLen && chars.allSatisfy { isCJK($0) } }
            .map { chars in (word: chars, reads: chars.map { self.fuzzySet($0) }) }
            .sorted { $0.word.count > $1.word.count }
    }

    var isActive: Bool { loaded && !words.isEmpty }

    private func isCJK(_ c: Character) -> Bool {
        guard c.unicodeScalars.count == 1, let v = c.unicodeScalars.first?.value else { return false }
        return (0x3400...0x4DBF).contains(v) || (0x4E00...0x9FFF).contains(v) || (0xF900...0xFAFF).contains(v)
    }

    /// Normalize a toneless syllable for FUZZY matching, merging the most common
    /// accent confusions so they compare equal:
    ///   • retroflex/flat: zh/ch/sh → z/c/s   (是 shi ≈ 四 si)
    ///   • l ↔ n:           n… → l…           (牛 niu ≈ 刘 liu)
    ///   • front/back nasal: ing/eng/ang → in/en/an  (京 jing ≈ 金 jin)
    static func fuzzyKey(_ p: String) -> String {
        var s = p
        if s.hasPrefix("zh") || s.hasPrefix("ch") || s.hasPrefix("sh") {
            s.remove(at: s.index(after: s.startIndex))   // drop the 'h'
        }
        if s.hasPrefix("n") { s = "l" + String(s.dropFirst()) }
        if s.hasSuffix("ing") { s = String(s.dropLast(3)) + "in" }
        else if s.hasSuffix("eng") { s = String(s.dropLast(3)) + "en" }
        else if s.hasSuffix("ang") { s = String(s.dropLast(3)) + "an" }
        return s
    }

    /// A char's readings collapsed to fuzzy keys (empty for non-CJK / unknown).
    private func fuzzySet(_ c: Character) -> Set<String> {
        guard let r = table[c] else { return [] }
        return Set(r.map { Self.fuzzyKey($0) })
    }

    /// Rewrite homophone runs into their dictionary spelling.
    func normalize(_ text: String) -> String {
        guard isActive else { return text }
        return normalize(text, prepared: words)
    }

    private func normalize(_ text: String, prepared: [(word: [Character], reads: [Set<String>])]) -> String {
        guard loaded, !prepared.isEmpty else { return text }
        let chars = Array(text)
        var out: [Character] = []
        out.reserveCapacity(chars.count)
        var i = 0
        while i < chars.count {
            var matched = false
            for (word, reads) in prepared {  // longest first
                let L = word.count
                guard i + L <= chars.count else { continue }
                if word == Array(chars[i..<i+L]) { continue }   // already exact → leave it
                var ok = true
                for k in 0..<L {
                    // both sides share a FUZZY reading (l/n, zh-z, in-ing… merged)
                    let r = fuzzySet(chars[i + k])
                    if !r.isEmpty, !reads[k].isEmpty, !r.isDisjoint(with: reads[k]) { continue }
                    ok = false; break
                }
                if ok {
                    out.append(contentsOf: word)
                    i += L
                    matched = true
                    break
                }
            }
            if !matched {
                out.append(chars[i])
                i += 1
            }
        }
        return String(out)
    }
}
