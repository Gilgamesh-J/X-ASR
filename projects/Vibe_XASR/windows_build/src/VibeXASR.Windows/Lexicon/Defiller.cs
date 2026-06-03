using System.Text.RegularExpressions;

namespace VibeXASR.Windows.Lexicon;

/// <summary>
/// Remove Chinese filler words from FINAL dictation — the touch that makes speech read like
/// writing (Typeless / Willow / WisprFlow all do this). Conservative: deletes pure interjections
/// (嗯/呃/唉…) and collapses ≥3× repeats, so genuine reduplications (看看 / 想想 / 好好) stay and a
/// single meaningful 那个 / 就是 is left intact — only stutter-style repeats fold.
/// Faithful port of macOS Defiller.swift.
/// </summary>
internal static class Defiller
{
    private const string Interjections = "嗯呃唉欸額额诶喔噢";
    private static readonly string[] RepeatWords = { "那个", "这个", "就是", "然后" };

    public static string Clean(string? text)
    {
        if (string.IsNullOrEmpty(text)) return text ?? string.Empty;
        var s = text;
        // 1) pure interjections (and any run of them)
        s = Regex.Replace(s, "[" + Interjections + "]+", "");
        // 2) collapse a character repeated ≥3× → once (2× e.g. 看看/想想 untouched)
        s = Regex.Replace(s, @"(.)\1{2,}", "$1");
        // 3) collapse stutter repeats of common fillers (≥2×) → once
        foreach (var w in RepeatWords) s = Regex.Replace(s, "(?:" + w + "){2,}", w);
        // 4) tidy punctuation left behind by removed interjections
        s = Regex.Replace(s, @"^[，,、。!?！？\s]+", "");
        s = Regex.Replace(s, "([，,])[，,]+", "$1");
        return s;
    }
}
