import Foundation

/// Lightweight, rule-based Chinese Inverse Text Normalization (ITN): rewrite
/// spoken-form numerals into written form for the *final* recognized text —
/// "一百二十三" → "123", "二零二四年" → "2024年", "三点半" → "3:30",
/// "百分之二十五" → "25%", "五千八百块" → "5800块", "端口八零八零" → "8080".
///
/// Conservative by design: only converts (a) STRUCTURED numbers (containing
/// 十/百/千/万/亿), (b) strong scenarios (percent / year / date / time / money /
/// units / decimals), and (c) digit runs that contain 零. Bare single-digit words
/// are left alone, so idioms and fillers ("第一", "等一下", "一带一路", "不三不四",
/// "三个人") are NOT touched. Pure local, zero latency, no dependencies.
enum ChineseITN {

    private static let num: [Character: Int] = [
        "零":0,"〇":0,"一":1,"二":2,"两":2,"三":3,"四":4,"五":5,
        "六":6,"七":7,"八":8,"九":9,"幺":1]
    private static let unit: [Character: Int] = ["十":10,"百":100,"千":1000]
    private static let big: [Character: Int] = ["万":10000,"亿":100000000]

    /// Parse a structured Chinese number ("一百二十三" → 123). Returns nil if `s`
    /// contains anything that isn't a numeral/unit char.
    static func cn2int(_ s: String) -> Int? {
        var total = 0, section = 0, n = 0; var seen = false
        for ch in s {
            // Two consecutive bare digits (e.g. "一二三…") is a digit string being
            // counted out, NOT a structured number — bail so "一二三四五六七八九十"
            // stays as-is instead of collapsing to 90.
            if let v = num[ch] { if n != 0 { return nil }; n = v; seen = true }
            else if let u = unit[ch] { section += (n == 0 ? 1 : n) * u; n = 0; seen = true }
            else if let b = big[ch] { section += n; total += section * b; section = 0; n = 0; seen = true }
            else { return nil }
        }
        return seen ? total + section + n : nil
    }

    /// Digit-by-digit ("二零二四" → "2024", "幺三八" → "138").
    static func digits(_ s: String) -> String {
        String(s.compactMap { num[$0].map { Character("\($0)") } })
    }

    /// Apply `transform` to every match of `pattern`; transform returns nil to keep
    /// the original match. Groups[0] is the whole match, groups[1...] are captures.
    private static func replace(_ s: String, _ pattern: String, _ transform: ([String]) -> String?) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return s }
        let ns = s as NSString
        var out = ""; var last = 0
        re.enumerateMatches(in: s, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
            guard let m = m else { return }
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            var g: [String] = []
            for i in 0..<m.numberOfRanges {
                let r = m.range(at: i)
                g.append(r.location == NSNotFound ? "" : ns.substring(with: r))
            }
            out += transform(g) ?? g[0]
            last = m.range.location + m.range.length
        }
        out += ns.substring(from: last)
        return out
    }

    private static let CN = "[零〇一二两三四五六七八九十百千万亿幺]"

    /// Run ITN over `text`. Call only on FINAL text (not streaming partials, where
    /// numbers would jump as you speak).
    static func normalize(_ text: String) -> String {
        var t = text
        // 1) percent
        t = replace(t, "百分之(\(CN)+)") { g in cn2int(g[1]).map { "\($0)%" } }
        // 2) time — only with a signal (period word OR 半/刻/分/钟), so "一点/三点" alone is untouched
        t = replace(t, "(上午|下午|早上|晚上|凌晨|中午)?([一二两三四五六七八九十]+)点((?:半|一刻|三刻|[零一二三四五六七八九十]+分|钟))?") { g in
            let period = g[1], tail = g[3]
            guard let h = cn2int(g[2]), h <= 24, !(period.isEmpty && tail.isEmpty) else { return nil }
            let mm: Int
            if tail.contains("半") { mm = 30 }
            else if tail.contains("一刻") { mm = 15 }
            else if tail.contains("三刻") { mm = 45 }
            else if tail.contains("分") { guard let m = cn2int(tail.replacingOccurrences(of: "分", with: "")) else { return nil }; mm = m }
            else { mm = 0 }
            return String(format: "%@%d:%02d", period, h, mm)
        }
        // 3) year (digit-by-digit, 2–4 digits + 年)
        t = replace(t, "([零〇一二三四五六七八九]{2,4})年") { g in "\(digits(g[1]))年" }
        // 4) month / day
        t = replace(t, "(\(CN)+)(月|号|日)") { g in cn2int(g[1]).map { "\($0)\(g[2])" } }
        // 5) money / temperature / common units
        t = replace(t, "(\(CN)+)(块钱|块|元|美元|美金|港币|人民币|度|倍|公斤|千克|公里|千米|毫米|厘米|米|小时|分钟|秒|个百分点)") { g in
            cn2int(g[1]).map { "\($0)\(g[2])" }
        }
        // 6) decimal (X点Y)
        t = replace(t, "([零〇一二两三四五六七八九十百千万亿]+)点([零〇一二三四五六七八九]+)") { g in
            cn2int(g[1]).map { "\($0).\(digits(g[2]))" }
        }
        // 7) structured integer (must contain 十/百/千/万/亿)
        t = replace(t, "[零〇一二两三四五六七八九]*[十百千万亿]\(CN)*") { g in cn2int(g[0]).map { String($0) } }
        // 8) digit run containing 零 (ports / codes — strong numeric signal)
        t = replace(t, "[幺零〇一二三四五六七八九]*零[幺零〇一二三四五六七八九]*") { g in
            g[0].count >= 2 ? digits(g[0]) : nil
        }
        return t
    }
}
