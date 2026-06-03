using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.RegularExpressions;

namespace VibeXASR.Windows.Lexicon;

/// <summary>
/// Persists the user's hotword list to a plain-text file sherpa-onnx loads (one phrase per line).
/// Faithful port of the macOS HotwordsStore: normalize (trim, drop blanks + '#' comments),
/// space-separate CJK chars (this model has no bare-char tokens — each CJK char maps to its own
/// ▁-piece via the augmented bpe.vocab), per-word boost (CJK uses the full score; pure-English is
/// capped ≤2.5 and ALSO emitted capitalized-first since the model only emits capitalized pieces),
/// atomic write. Writing an empty list removes the file so the engine stays on greedy_search
/// (zero behaviour change).
/// </summary>
public static class HotwordsStore
{
    private static readonly Regex ScoreSuffix = new(@"\s:\d+(\.\d+)?$", RegexOptions.Compiled);

    public static List<string> Normalize(string? text) =>
        (text ?? "").Split('\n', '\r')
            .Select(l => l.Trim())
            .Where(l => l.Length > 0 && !l.StartsWith("#"))
            .ToList();

    public static int Count(string? text) => Normalize(text).Count;

    private static bool IsCjk(char c) =>
        (c >= 0x3400 && c <= 0x4DBF) || (c >= 0x4E00 && c <= 0x9FFF) || (c >= 0xF900 && c <= 0xFAFF);

    /// <summary>Space-separate every CJK char; English words intact; trailing " :score" preserved.
    /// e.g. "我用OpenAI" → "我 用 OpenAI", "李沐 :2.5" → "李 沐 :2.5".</summary>
    public static string SpaceCjk(string s)
    {
        var sb = new StringBuilder(s.Length * 2);
        foreach (var ch in s)
        {
            if (IsCjk(ch)) sb.Append(' ').Append(ch).Append(' ');
            else sb.Append(ch);
        }
        return string.Join(" ", sb.ToString().Split(' ', StringSplitOptions.RemoveEmptyEntries));
    }

    private static string FmtScore(double s) =>
        s == Math.Round(s) ? ((int)s).ToString(CultureInfo.InvariantCulture)
                           : s.ToString("0.###", CultureInfo.InvariantCulture);

    /// <summary>Append a per-word boost: CJK terms use the full score; pure-English is capped ≤2.5
    /// (over-boosting English distorts words). An explicit trailing " :N" is respected as-is.</summary>
    public static string WithBoost(string line, double score)
    {
        var m = ScoreSuffix.Match(line);
        if (m.Success)
        {
            var word = line.Substring(0, m.Index);
            var suffix = line.Substring(m.Index).Trim();
            return SpaceCjk(word) + " " + suffix;
        }
        double s = line.Any(IsCjk) ? score : Math.Min(score, 2.5);
        return SpaceCjk(line) + " :" + FmtScore(s);
    }

    public static string CapitalizedFirst(string s) =>
        s.Length == 0 ? s : char.ToUpperInvariant(s[0]) + s.Substring(1);

    /// <summary>Expand a raw line into prepared line(s). A pure-English word ALSO emits a
    /// capitalized-first variant (the model emits "▁Py", never "▁py").</summary>
    public static List<string> Expand(string line, double score)
    {
        if (ScoreSuffix.IsMatch(line) || line.Any(IsCjk)) return new() { WithBoost(line, score) };
        var cap = CapitalizedFirst(line);
        var variants = cap == line ? new List<string> { line } : new List<string> { line, cap };
        return variants.Select(v => WithBoost(v, score)).ToList();
    }

    /// <summary>Write the prepared list to <paramref name="path"/>; remove it when empty. Returns
    /// true if a non-empty file was written.</summary>
    public static bool WriteFile(string? text, double score, string path)
    {
        var lines = Normalize(text).SelectMany(l => Expand(l, score)).ToList();
        try
        {
            if (lines.Count == 0) { if (File.Exists(path)) File.Delete(path); return false; }
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            File.WriteAllText(path, string.Join("\n", lines) + "\n", new UTF8Encoding(false));
            return true;
        }
        catch (Exception ex) { Diag.Log("hotwords write failed: " + ex.Message); return false; }
    }

    public static bool IsNonEmpty(string path)
    {
        try { return File.Exists(path) && new FileInfo(path).Length > 0; }
        catch { return false; }
    }
}
