using System;
using System.Collections.Generic;
using System.Linq;
using System.Text.RegularExpressions;

namespace VibeXASR.Windows.Lexicon;

/// <summary>
/// Post-recognition text replacement. Each rule is "from => to" (also accepts "->"). Applied in a
/// SINGLE left-to-right pass (longest "from" first, case-insensitive) so a replacement is never
/// re-matched by a later rule. Faithful port of the macOS Replacements.
/// </summary>
public static class Replacements
{
    public readonly record struct Rule(string From, string To);

    /// <summary>Parse "from => to" / "from -> to" lines; skip blanks and '#' comments.</summary>
    public static List<Rule> Parse(string? text)
    {
        var rules = new List<Rule>();
        foreach (var raw in (text ?? "").Split('\n', '\r'))
        {
            var line = raw.Trim();
            if (line.Length == 0 || line.StartsWith("#")) continue;
            int sep = line.IndexOf("=>", StringComparison.Ordinal);
            if (sep < 0) sep = line.IndexOf("->", StringComparison.Ordinal);
            if (sep < 0) continue;
            var from = line.Substring(0, sep).Trim();
            var to = line.Substring(sep + 2).Trim();
            if (from.Length == 0) continue;
            rules.Add(new Rule(from, to));
        }
        return rules;
    }

    public static int Count(string? text) => Parse(text).Count;

    /// <summary>Apply rules to <paramref name="text"/> in one pass (longest-first, case-insensitive).</summary>
    public static string Apply(string text, IReadOnlyList<Rule> rules)
    {
        var sorted = rules.Where(r => r.From.Length > 0).OrderByDescending(r => r.From.Length).ToList();
        if (sorted.Count == 0) return text;
        var pattern = string.Join("|", sorted.Select(r => Regex.Escape(r.From)));
        Regex re;
        try { re = new Regex(pattern, RegexOptions.IgnoreCase); }
        catch { return text; }
        return re.Replace(text, m =>
        {
            foreach (var r in sorted)
                if (string.Equals(r.From, m.Value, StringComparison.OrdinalIgnoreCase)) return r.To;
            return m.Value;
        });
    }

    /// <summary>Snippet expansion (口令): a spoken trigger → (possibly multi-line) saved text.
    /// Unlike <see cref="Apply"/>: (1) the trigger tolerates whitespace BETWEEN characters, so a
    /// spelled-out "C C" (this model emits letters spaced) matches a trigger "cc"; (2) it swallows
    /// one trailing sentence-final mark (。.!?！? but NOT a comma) after the hit, so the expansion
    /// lands clean instead of inheriting the auto-period the engine appends to a finalized
    /// utterance. Single left-to-right pass (longest trigger first). Port of macOS Replacements.expand.</summary>
    public static string Expand(string text, IReadOnlyList<Rule> rules)
    {
        if (string.IsNullOrEmpty(text) || rules.Count == 0) return text ?? string.Empty;
        var sorted = rules.Where(r => r.From.Length > 0).OrderByDescending(r => r.From.Length).ToList();
        if (sorted.Count == 0) return text;
        var alts = sorted.Select(r => "(" + string.Join(@"\s*", r.From.Select(c => Regex.Escape(c.ToString()))) + ")");
        var pattern = "(?:" + string.Join("|", alts) + @")\s*[。.!?！？]?";
        Regex re;
        try { re = new Regex(pattern, RegexOptions.IgnoreCase); }
        catch { return text; }
        return re.Replace(text, m =>
        {
            for (int i = 0; i < sorted.Count; i++)
                if (m.Groups[i + 1].Success) return sorted[i].To;
            return m.Value;
        });
    }
}
