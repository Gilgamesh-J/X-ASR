import Foundation

enum HotwordCanonicalizer {
    static func rewrite(_ text: String, canonicalWords: [String], aliases: [String: String] = [:]) -> String {
        var out = text
        for rule in rewriteRules(canonicalWords: canonicalWords, aliases: aliases) {
            out = replace(in: out, alias: rule.alias, canonical: rule.canonical)
        }
        return out
    }

    private static func rewriteRules(canonicalWords: [String], aliases: [String: String]) -> [(alias: String, canonical: String)] {
        var out: [(alias: String, canonical: String)] = []
        var seen = Set<String>()

        func append(alias: String, canonical: String) {
            let trimmedAlias = alias.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedCanonical = canonical.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedAlias.isEmpty, !trimmedCanonical.isEmpty else { return }
            let key = trimmedAlias.lowercased() + "\u{1f}" + trimmedCanonical
            guard seen.insert(key).inserted else { return }
            out.append((trimmedAlias, trimmedCanonical))
        }

        for canonical in canonicalWords {
            append(alias: canonical, canonical: canonical)
            for alias in autoAliases(for: canonical) {
                append(alias: alias, canonical: canonical)
            }
        }
        for (alias, canonical) in aliases {
            append(alias: alias, canonical: canonical)
        }

        return out.sorted {
            if $0.alias.count != $1.alias.count { return $0.alias.count > $1.alias.count }
            return $0.canonical.count > $1.canonical.count
        }
    }

    private static func autoAliases(for canonical: String) -> [String] {
        guard isASCIIish(canonical) else { return [] }
        var out = Set<String>()
        let compact = canonical.replacingOccurrences(of: " ", with: "")

        if let camel = splitCamelOrAcronym(compact), !equalsIgnoringCaseAndSpace(camel, canonical) {
            out.insert(camel)
        }
        if compact.contains(".") {
            out.insert(compact.replacingOccurrences(of: ".", with: " "))
            out.insert(compact.replacingOccurrences(of: ".", with: ""))
        }
        if compact.contains("-") {
            out.insert(compact.replacingOccurrences(of: "-", with: " "))
            out.insert(compact.replacingOccurrences(of: "-", with: ""))
        }
        if isAllInitialism(compact) {
            out.insert(compact.map(String.init).joined(separator: " "))
        }
        if canonical.contains(" ") {
            out.insert(canonical.replacingOccurrences(of: " ", with: ""))
        }
        out.remove(canonical)
        return Array(out)
    }

    private static func equalsIgnoringCaseAndSpace(_ lhs: String, _ rhs: String) -> Bool {
        lhs.replacingOccurrences(of: " ", with: "").lowercased()
        == rhs.replacingOccurrences(of: " ", with: "").lowercased()
    }

    private static func splitCamelOrAcronym(_ text: String) -> String? {
        guard !text.isEmpty else { return nil }
        var out = ""
        let chars = Array(text)
        for idx in chars.indices {
            let ch = chars[idx]
            if idx > 0 {
                let prev = chars[idx - 1]
                let next = idx + 1 < chars.count ? chars[idx + 1] : nil
                let breakBeforeUpper =
                    ch.isASCIIUppercase && (prev.isASCIILowercase || prev.isASCIIDigit)
                let breakBeforeTrailingWord =
                    ch.isASCIIUppercase && prev.isASCIIUppercase && next?.isASCIILowercase == true
                if breakBeforeUpper || breakBeforeTrailingWord { out.append(" ") }
            }
            out.append(ch)
        }
        return out.contains(" ") ? out : nil
    }

    private static func isAllInitialism(_ text: String) -> Bool {
        let compact = text.replacingOccurrences(of: ".", with: "")
        guard compact.count >= 2 else { return false }
        return compact.allSatisfy { $0.isASCIIUppercase || $0.isNumber }
    }

    private static func isASCIIish(_ word: String) -> Bool {
        word.unicodeScalars.allSatisfy { $0.value < 128 && !$0.properties.isWhitespace }
            || word.unicodeScalars.allSatisfy { $0.value < 128 }
    }

    private static func replace(in text: String, alias: String, canonical: String) -> String {
        if alias.contains(where: isCJK) {
            return text.replacingOccurrences(of: alias, with: canonical)
        }
        let pattern = asciiWholePhrasePattern(for: alias)
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return text
        }
        let ns = text as NSString
        var out = ""
        var last = 0
        re.enumerateMatches(in: text, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
            guard let r = m?.range else { return }
            out += ns.substring(with: NSRange(location: last, length: r.location - last))
            out += canonical
            last = r.location + r.length
        }
        out += ns.substring(from: last)
        return out
    }

    private static func asciiWholePhrasePattern(for alias: String) -> String {
        let parts = alias.split(whereSeparator: \.isWhitespace).map { NSRegularExpression.escapedPattern(for: String($0)) }
        let body = parts.joined(separator: #"\s+"#)
        return #"(?<![A-Za-z0-9])"# + body + #"(?![A-Za-z0-9])"#
    }

    private static func isCJK(_ c: Character) -> Bool {
        guard c.unicodeScalars.count == 1, let v = c.unicodeScalars.first?.value else { return false }
        return (0x3400...0x4DBF).contains(v) || (0x4E00...0x9FFF).contains(v) || (0xF900...0xFAFF).contains(v)
    }
}

private extension Character {
    var isASCIIUppercase: Bool { ("A"..."Z").contains(self) }
    var isASCIILowercase: Bool { ("a"..."z").contains(self) }
    var isASCIIDigit: Bool { ("0"..."9").contains(self) }
}
