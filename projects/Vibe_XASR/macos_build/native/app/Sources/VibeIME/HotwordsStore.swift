import Foundation

/// Persists the user's hotword list to a plain-text file the sherpa-onnx engine
/// loads (one phrase per line). Normalizes on write: trims each line, drops blank
/// lines and `#` comments. Writing an empty list removes the file so the engine
/// falls back to greedy_search with no biasing (zero behaviour change).
///
/// Format notes (sherpa-onnx hotwords-file):
///   * one phrase per line, UTF-8, Chinese / English / mixed written verbatim;
///   * a trailing ` :2.5` on a line overrides the per-word boost.
enum HotwordsStore {

    /// Split the raw editor text into normalized hotword lines.
    static func normalize(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    /// Number of effective hotwords in the raw text (for the UI counter).
    static func count(_ text: String) -> Int { normalize(text).count }

    private static func isCJK(_ c: Character) -> Bool {
        guard c.unicodeScalars.count == 1, let v = c.unicodeScalars.first?.value else { return false }
        return (0x3400...0x4DBF).contains(v) || (0x4E00...0x9FFF).contains(v) || (0xF900...0xFAFF).contains(v)
    }

    /// Space-separate every CJK character so sherpa's BPE tokenizer maps each to
    /// its own ▁-prefixed piece (this model has no bare-char tokens). English
    /// words are left intact; a trailing " :score" boost suffix is preserved.
    /// e.g. "我用OpenAI" → "我 用 OpenAI", "李沐 :2.5" → "李 沐 :2.5".
    static func spaceCJK(_ s: String) -> String {
        var out = ""
        for ch in s {
            if isCJK(ch) { out += " "; out.append(ch); out += " " } else { out.append(ch) }
        }
        return out.split(separator: " ").joined(separator: " ")
    }

    /// Format a score compactly (5.0 → "5", 2.5 → "2.5").
    private static func fmtScore(_ s: Double) -> String {
        s == s.rounded() ? String(Int(s)) : String(format: "%g", s)
    }

    /// Per-word boost so ONE UI strength works for both scripts: CJK terms are
    /// char-level and need a stronger push (`score`); pure-English terms are
    /// capped lower (≤2.5) because over-boosting English distorts words. An
    /// explicit trailing " :N" the user typed is respected as-is.
    static func withBoost(_ line: String, score: Double) -> String {
        if let r = line.range(of: #"\s:\d+(\.\d+)?$"#, options: .regularExpression) {
            let word = String(line[..<r.lowerBound])
            let suffix = String(line[r.lowerBound...]).trimmingCharacters(in: .whitespaces)
            return spaceCJK(word) + " " + suffix
        }
        let s = line.contains(where: isCJK) ? score : min(score, 2.5)
        return spaceCJK(line) + " :" + fmtScore(s)
    }

    /// Capitalize just the first character ("pytorch" → "Pytorch").
    static func capitalizedFirst(_ s: String) -> String {
        guard let f = s.first else { return s }
        return f.uppercased() + String(s.dropFirst())
    }

    /// Expand a raw hotword line into the prepared line(s) written to disk. For a
    /// pure-English word we ALSO emit a capitalized-first variant, because the
    /// model only emits capitalized proper-noun pieces (e.g. "▁Py" in "PyTorch")
    /// and never lowercase "▁py", so a lowercase entry like "pytorch" would match
    /// nothing. CJK / explicit-boost lines pass through unchanged.
    static func expand(_ line: String, score: Double) -> [String] {
        let hasExplicit = line.range(of: #"\s:\d+(\.\d+)?$"#, options: .regularExpression) != nil
        if hasExplicit || line.contains(where: isCJK) {
            return [withBoost(line, score: score)]
        }
        let cap = capitalizedFirst(line)
        let variants = (cap == line) ? [line] : [line, cap]
        return variants.map { withBoost($0, score: score) }
    }

    /// Write the normalized list to `url`, appending a per-word boost derived from
    /// `score` (and English case variants). Removes the file when the list is
    /// empty. Returns true when a non-empty file was written.
    @discardableResult
    static func writeFile(text: String, score: Double, to url: URL) -> Bool {
        let lines = normalize(text).flatMap { expand($0, score: score) }
        let fm = FileManager.default
        guard !lines.isEmpty else {
            try? fm.removeItem(at: url)
            return false
        }
        let body = lines.joined(separator: "\n") + "\n"
        do {
            try body.write(to: url, atomically: true, encoding: .utf8)
            return true
        } catch {
            FileHandle.standardError.write(
                "[VibeIME] hotwords write failed: \(error)\n".data(using: .utf8)!)
            return false
        }
    }

    /// True if the file exists and is non-empty.
    static func isNonEmpty(_ url: URL) -> Bool {
        guard let sz = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int
        else { return false }
        return sz > 0
    }
}
