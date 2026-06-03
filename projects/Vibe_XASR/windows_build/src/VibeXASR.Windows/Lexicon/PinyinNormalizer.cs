using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;

namespace VibeXASR.Windows.Lexicon;

/// <summary>
/// Homophone correction by pinyin: rewrite a run of CJK chars that SOUNDS like a dictionary word
/// into that word's exact spelling (e.g. 贾阳清/嘉阳清/贾杨青 → 贾扬清). Faithful port of the macOS
/// PinyinNormalizer. Loads a char→toneless-pinyin table (pinyin.txt); only the user's multi-char,
/// all-CJK dictionary words drive it (longest-first, fuzzy tone-insensitive matching). Inert when
/// the table or word list is empty.
/// </summary>
public sealed class PinyinNormalizer
{
    private Dictionary<char, HashSet<string>> _table = new();
    private bool _loaded;
    // Dictionary words (CJK only), longest first, with each char's fuzzy-reading set precomputed.
    private List<(char[] Word, HashSet<string>[] Reads)> _words = new();
    private const int MinLen = 2;

    public bool IsActive => _loaded && _words.Count > 0;

    /// <summary>Load the 汉字→拼音 table once (format: "char py1 py2 …"). No-op if missing.</summary>
    public void LoadTableIfNeeded(string? path)
    {
        if (_loaded || string.IsNullOrEmpty(path) || !File.Exists(path)) return;
        try
        {
            var t = new Dictionary<char, HashSet<string>>(28000);
            foreach (var line in File.ReadLines(path))
            {
                var parts = line.Split(' ', StringSplitOptions.RemoveEmptyEntries);
                if (parts.Length == 0 || parts[0].Length == 0) continue;
                t[parts[0][0]] = new HashSet<string>(parts.Skip(1));
            }
            _table = t;
            _loaded = true;
        }
        catch (Exception ex) { Diag.Log("pinyin table load failed: " + ex.Message); }
    }

    private static bool IsCjk(char c) =>
        (c >= 0x3400 && c <= 0x4DBF) || (c >= 0x4E00 && c <= 0x9FFF) || (c >= 0xF900 && c <= 0xFAFF);

    /// <summary>Collapse the common accent confusions so they compare equal:
    /// zh/ch/sh→z/c/s, n…→l…, ing/eng/ang→in/en/an.</summary>
    public static string FuzzyKey(string p)
    {
        var s = p;
        if (s.StartsWith("zh") || s.StartsWith("ch") || s.StartsWith("sh")) s = s[0] + s.Substring(2);
        if (s.StartsWith("n")) s = "l" + s.Substring(1);
        if (s.EndsWith("ing")) s = s.Substring(0, s.Length - 3) + "in";
        else if (s.EndsWith("eng")) s = s.Substring(0, s.Length - 3) + "en";
        else if (s.EndsWith("ang")) s = s.Substring(0, s.Length - 3) + "an";
        return s;
    }

    private HashSet<string> FuzzySet(char c) =>
        _table.TryGetValue(c, out var r) ? new HashSet<string>(r.Select(FuzzyKey)) : new HashSet<string>();

    /// <summary>Set the active dictionary words — only multi-char, all-CJK words are used.</summary>
    public void SetWords(IEnumerable<string> raw)
    {
        _words = raw
            .Select(w => w.ToCharArray())
            .Where(chars => chars.Length >= MinLen && chars.All(IsCjk))
            .Select(chars => (Word: chars, Reads: chars.Select(FuzzySet).ToArray()))
            .OrderByDescending(t => t.Word.Length)
            .ToList();
    }

    /// <summary>Rewrite homophone runs into their dictionary spelling.</summary>
    public string Normalize(string text)
    {
        if (!IsActive) return text;
        var chars = text.ToCharArray();
        var outp = new List<char>(chars.Length);
        int i = 0;
        while (i < chars.Length)
        {
            bool matched = false;
            foreach (var (word, reads) in _words) // longest first
            {
                int L = word.Length;
                if (i + L > chars.Length) continue;
                if (MatchesExact(chars, i, word)) continue; // already exact → leave it
                bool ok = true;
                for (int k = 0; k < L; k++)
                {
                    var r = FuzzySet(chars[i + k]);
                    if (r.Count > 0 && reads[k].Count > 0 && r.Overlaps(reads[k])) continue;
                    ok = false; break;
                }
                if (ok) { outp.AddRange(word); i += L; matched = true; break; }
            }
            if (!matched) { outp.Add(chars[i]); i++; }
        }
        return new string(outp.ToArray());
    }

    private static bool MatchesExact(char[] chars, int i, char[] word)
    {
        for (int k = 0; k < word.Length; k++) if (chars[i + k] != word[k]) return false;
        return true;
    }
}
