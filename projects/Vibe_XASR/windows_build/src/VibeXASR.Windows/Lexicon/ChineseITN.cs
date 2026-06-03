using System;
using System.Collections.Generic;
using System.Text;
using System.Text.RegularExpressions;

namespace VibeXASR.Windows.Lexicon;

/// <summary>
/// Lightweight, rule-based Chinese Inverse Text Normalization (ITN): rewrite spoken-form numerals
/// into written form for the FINAL recognized text — "一百二十三"→"123", "二零二四年"→"2024年",
/// "三点半"→"3:30", "百分之二十五"→"25%", "五千八百块"→"5800块", "端口八零八零"→"8080".
///
/// Conservative by design: only converts (a) STRUCTURED numbers (containing 十/百/千/万/亿),
/// (b) strong scenarios (percent / year / date / time / money / units / decimals), and (c) digit
/// runs containing 零. Bare single-digit words are left alone, so idioms and fillers ("第一",
/// "等一下", "一带一路", "不三不四", "三个人") are NOT touched. Pure local, zero latency.
/// Faithful port of macOS ChineseITN.swift.
/// </summary>
internal static class ChineseITN
{
    private static readonly Dictionary<char, long> Num = new()
    {
        ['零'] = 0, ['〇'] = 0, ['一'] = 1, ['二'] = 2, ['两'] = 2, ['三'] = 3, ['四'] = 4, ['五'] = 5,
        ['六'] = 6, ['七'] = 7, ['八'] = 8, ['九'] = 9, ['幺'] = 1,
    };
    private static readonly Dictionary<char, long> Unit = new() { ['十'] = 10, ['百'] = 100, ['千'] = 1000 };
    private static readonly Dictionary<char, long> Big = new() { ['万'] = 10000, ['亿'] = 100000000 };

    /// <summary>Parse a structured Chinese number ("一百二十三" → 123). Null if `s` has a non-numeral char.</summary>
    private static long? Cn2Int(string s)
    {
        long total = 0, section = 0, n = 0; bool seen = false;
        foreach (var ch in s)
        {
            if (Num.TryGetValue(ch, out var v)) { n = v; seen = true; }
            else if (Unit.TryGetValue(ch, out var u)) { section += (n == 0 ? 1 : n) * u; n = 0; seen = true; }
            else if (Big.TryGetValue(ch, out var b)) { section += n; total += section * b; section = 0; n = 0; seen = true; }
            else return null;
        }
        return seen ? total + section + n : (long?)null;
    }

    /// <summary>Digit-by-digit ("二零二四" → "2024", "幺三八" → "138").</summary>
    private static string Digits(string s)
    {
        var sb = new StringBuilder();
        foreach (var ch in s) if (Num.TryGetValue(ch, out var v)) sb.Append((char)('0' + v));
        return sb.ToString();
    }

    private const string CN = "[零〇一二两三四五六七八九十百千万亿幺]";

    /// <summary>Run ITN over `text`. Call only on FINAL text (not streaming partials, where the
    /// numbers would visibly jump as you speak).</summary>
    public static string Normalize(string? text)
    {
        if (string.IsNullOrEmpty(text)) return text ?? string.Empty;
        var t = text;
        // 1) percent
        t = Sub(t, "百分之(" + CN + "+)", g => Cn2Int(g[1]) is long n ? n + "%" : null);
        // 2) time — needs a signal (period word OR 半/刻/分/钟), so "一点/三点" alone is untouched
        t = Sub(t, "(上午|下午|早上|晚上|凌晨|中午)?([一二两三四五六七八九十]+)点((?:半|一刻|三刻|[零一二三四五六七八九十]+分|钟))?", g =>
        {
            string period = g[1], tail = g[3];
            if (Cn2Int(g[2]) is not long h || h > 24 || (period.Length == 0 && tail.Length == 0)) return null;
            int mm;
            if (tail.Contains("半")) mm = 30;
            else if (tail.Contains("一刻")) mm = 15;
            else if (tail.Contains("三刻")) mm = 45;
            else if (tail.Contains("分")) { if (Cn2Int(tail.Replace("分", "")) is not long m) return null; mm = (int)m; }
            else mm = 0;
            return $"{period}{h}:{mm:00}";
        });
        // 3) year (digit-by-digit, 2–4 digits + 年)
        t = Sub(t, "([零〇一二三四五六七八九]{2,4})年", g => Digits(g[1]) + "年");
        // 4) month / day
        t = Sub(t, "(" + CN + "+)(月|号|日)", g => Cn2Int(g[1]) is long n ? n + g[2] : null);
        // 5) money / temperature / common units
        t = Sub(t, "(" + CN + "+)(块钱|块|元|美元|美金|港币|人民币|度|倍|公斤|千克|公里|千米|毫米|厘米|米|小时|分钟|秒|个百分点)",
            g => Cn2Int(g[1]) is long n ? n + g[2] : null);
        // 6) decimal (X点Y)
        t = Sub(t, "([零〇一二两三四五六七八九十百千万亿]+)点([零〇一二三四五六七八九]+)",
            g => Cn2Int(g[1]) is long n ? n + "." + Digits(g[2]) : null);
        // 7) structured integer (must contain 十/百/千/万/亿)
        t = Sub(t, "[零〇一二两三四五六七八九]*[十百千万亿]" + CN + "*", g => Cn2Int(g[0]) is long n ? n.ToString() : null);
        // 8) digit run containing 零 (ports / codes — strong numeric signal)
        t = Sub(t, "[幺零〇一二三四五六七八九]*零[幺零〇一二三四五六七八九]*", g => g[0].Length >= 2 ? Digits(g[0]) : null);
        return t;
    }

    /// <summary>Apply `transform` to every match; transform returns null to keep the original match.
    /// g[0] is the whole match, g[1..] are captures (absent groups are "").</summary>
    private static string Sub(string s, string pattern, Func<string[], string?> transform)
        => Regex.Replace(s, pattern, m =>
        {
            var g = new string[m.Groups.Count];
            for (int i = 0; i < m.Groups.Count; i++) g[i] = m.Groups[i].Success ? m.Groups[i].Value : "";
            return transform(g) ?? m.Value;
        });
}
