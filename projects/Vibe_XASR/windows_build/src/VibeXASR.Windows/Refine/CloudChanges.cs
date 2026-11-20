using System;
using System.Collections.Generic;
using System.Text;

namespace VibeXASR.Windows.Refine;

/// <summary>
/// Turns "what the on-device rules changed" into the short human-readable list the cloud prompt's
/// {{changes}} slot expects ("同音字纠正: 「沈向阳」→「沈向洋」"). The prompt rule 5 asks the model to
/// double-check those local edits, so the list has to be the ACTUAL edits — before this file existed the
/// placeholder was always filled with "(无)" and the rule was dead weight.
///
/// Character-level LCS, capped: utterances are short (cloud polish only runs in 说完插入), and beyond the
/// cap we degrade to a length note instead of burning memory on a huge DP table.
/// </summary>
internal static class TextDiff
{
    private const int MaxCharsForDiff = 1200;

    /// <summary>One changed span: what the rule removed and what it put in its place.</summary>
    public readonly record struct Hunk(string Before, string After);

    /// <summary>"「旧」→「新」；…" — empty when nothing changed. Capped so the prompt stays small.</summary>
    public static string Describe(string before, string after, int maxHunks = 4, int maxChars = 240)
    {
        before ??= "";
        after ??= "";
        if (string.Equals(before, after, StringComparison.Ordinal)) return "";
        if (before.Length == 0 || after.Length == 0) return Format(before.Trim(), after.Trim());
        if (before.Length > MaxCharsForDiff || after.Length > MaxCharsForDiff)
            return $"长度 {before.Length} → {after.Length} 字";

        var hunks = Hunks(before, after, maxHunks);
        if (hunks.Count == 0) return "";
        var sb = new StringBuilder();
        foreach (var h in hunks)
        {
            if (sb.Length > 0) sb.Append("；");
            sb.Append(Format(h.Before.Trim(), h.After.Trim()));
        }
        var s = sb.ToString();
        return s.Length > maxChars ? s[..maxChars] + "…" : s;
    }

    /// <summary>The first <paramref name="limit"/> changed spans, with runs closer than 4 unchanged chars merged.</summary>
    public static List<Hunk> Hunks(string a, string b, int limit = 4)
    {
        int n = a.Length, m = b.Length;
        // LCS lengths from the end: lcs[i, j] = LCS(a[i..], b[j..]).
        var lcs = new ushort[n + 1, m + 1];
        for (int i = n - 1; i >= 0; i--)
            for (int j = m - 1; j >= 0; j--)
                lcs[i, j] = a[i] == b[j] ? (ushort)(lcs[i + 1, j + 1] + 1)
                          : Math.Max(lcs[i + 1, j], lcs[i, j + 1]);

        var hunks = new List<Hunk>();
        var del = new StringBuilder();
        var ins = new StringBuilder();
        var gap = new StringBuilder();
        int x = 0, y = 0;
        void Flush()
        {
            if (del.Length == 0 && ins.Length == 0) return;
            hunks.Add(new Hunk(del.ToString(), ins.ToString()));
            del.Clear(); ins.Clear();
        }
        while (x < n || y < m)
        {
            if (x < n && y < m && a[x] == b[y])
            {
                if (del.Length > 0 || ins.Length > 0)
                {
                    gap.Append(a[x]);
                    if (gap.Length >= 4) { Flush(); gap.Clear(); }   // far enough apart: keep them separate
                }
                x++; y++;
            }
            else if (y < m && (x == n || lcs[x, y + 1] >= lcs[x + 1, y]))
            {
                gap.Clear(); ins.Append(b[y]); y++;
            }
            else if (x < n)
            {
                gap.Clear(); del.Append(a[x]); x++;
            }
            else break;
        }
        Flush();
        return hunks.Count > limit ? hunks.GetRange(0, limit) : hunks;
    }

    private static string Quote(string s) => "「" + s + "」";

    /// <summary>「a」→「b」 for an edit, <c>-「a」</c> for a pure deletion, <c>+「b」</c> for a pure insertion.</summary>
    private static string Format(string before, string after) =>
        after.Length == 0 ? "-" + Quote(before)
      : before.Length == 0 ? "+" + Quote(after)
      : Quote(before) + " → " + Quote(after);
}
