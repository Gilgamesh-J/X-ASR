using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace VibeXASR.Windows.Refine;

/// <summary>A refinement backend (cloud / future local). Text in → polished out. Port of RefinerBackend.</summary>
internal interface IRefinerBackend
{
    /// <summary>Whether the backend is configured + ready. Not-ready → facade returns the input untouched.</summary>
    bool IsReady { get; }
    /// <summary>Refine the whole text once. Returns null when the backend can't handle it (caller falls back).</summary>
    Task<string?> RefineAsync(string system, string text, CancellationToken ct);
}

/// <summary>
/// AI refinement (Beta) — backend-agnostic facade. Faithful port of macOS Refiner.swift.
/// Coordinates backend inference + guardrails + fallback so ANY error/timeout/guardrail-reject safely
/// falls back to the rule-version text — never drops characters, never blocks insertion.
/// Hook point: TrayApp.OnFinal, after the rule chain (defiller/ITN/snippets), before insert.
/// </summary>
internal static class Refiner
{
    /// <summary>Current backend (null = unconfigured → PolishAsync is a safe no-op).</summary>
    public static IRefinerBackend? Backend;

    /// <summary>Inference timeout (seconds). Timeout → fall back to the rule version. Cloud is slow (3–8s typical).</summary>
    public static double TimeoutSeconds = 25.0;

    /// <summary>Instruction builder. Cloud = TrayApp builds it from the config (mods/template/hotwords, with
    /// {{hotwords}}/{{date}} already filled, may contain {{transcript}} for the backend to fill).</summary>
    public static Func<string> SystemProvider = () => SystemPrompt;

    /// <summary>Default fixed instruction: remove fillers + keep the final restatement; never touch numbers/English/names.</summary>
    public const string SystemPrompt =
        "你是语音转写(ASR)文本的整理助手。只做两件事:" +
        "① 删除口癖词(嗯、呃、那个、就是、然后那个 等)与明显重复;" +
        "② 若说话人中途改口(如「周二…不对周三」),只保留最终说法。" +
        "然后补全标点。若原文没有需要修改的,就原样输出原文,不要补充任何内容。" +
        "严禁复述本说明或任何指令,严禁解释,严禁翻译,严禁改动数字、英文与专有名词。" +
        "只输出整理后的文本本身。";

    public static bool Active => Backend?.IsReady == true;

    /// <summary>Polish final text. Failure/timeout/guardrail-reject → returns the input (safe fallback).</summary>
    public static async Task<string> PolishAsync(string text)
    {
        var backend = Backend;
        if (backend is null || !backend.IsReady || !ShouldRun(text)) return text;
        var sys = SystemProvider();
        string? raw;
        try
        {
            using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(TimeoutSeconds));
            raw = await backend.RefineAsync(sys, text, cts.Token).ConfigureAwait(false);
        }
        catch { raw = null; }                                   // timeout/cancel/error → fall back
        if (string.IsNullOrEmpty(raw)) return text;
        var outp = StripWrapping(raw!);
        if (string.IsNullOrEmpty(outp) || !Guardrails.Accept(text, outp)) return text;  // guardrail reject → fall back
        return outp;
    }

    /// <summary>Trigger gate: too short → skip (saves latency + risk). Port of shouldRun (≥6 chars).</summary>
    public static bool ShouldRun(string text) => text.Trim().Length >= 6;

    /// <summary>Clean model output: strip stray wrapping quotes and leftover &lt;think&gt;…&lt;/think&gt;.</summary>
    public static string StripWrapping(string s)
    {
        var t = s.Trim();
        int open = t.IndexOf("<think>", StringComparison.OrdinalIgnoreCase);
        int close = t.IndexOf("</think>", StringComparison.OrdinalIgnoreCase);
        if (open >= 0 && close >= 0 && close > open)
            t = (t.Substring(0, open) + t.Substring(close + "</think>".Length)).Trim();
        var quotes = new HashSet<char> { '"', '“', '”', '「', '」', '\'' };
        if (t.Length > 0 && quotes.Contains(t[0])) t = t.Substring(1);
        if (t.Length > 0 && quotes.Contains(t[^1])) t = t.Substring(0, t.Length - 1);
        return t.Trim();
    }
}

/// <summary>Guardrails: prevent the refiner from losing info / mangling. Any reject → caller falls back.
/// Faithful port of macOS Guardrails. Pure logic.</summary>
internal static class Guardrails
{
    /// <summary>Output shorter than the source by more than this ratio → "deleted too much" reject. A genuine
    /// restatement can legitimately drop the first half (~60% measured), so 0.7 only catches extreme loss.</summary>
    public const double MaxShrink = 0.7;

    public static bool Accept(string src, string outp)
    {
        if (LooksLikePromptLeak(src, outp)) return false;       // model parroted the instruction → reject
        if (!EnglishKept(src, outp)) return false;              // every English word must survive
        if (!DigitsKept(src, outp)) return false;               // every Arabic-digit run must survive
        var shrink = 1.0 - (double)outp.Length / Math.Max(src.Length, 1);
        return shrink <= MaxShrink;                             // length-collapse backstop
    }

    /// <summary>Prompt-leak detection: small models sometimes echo the system instruction into the output.
    /// Output contains an instruction marker that the source did not → treat as leak, fall back.</summary>
    public static bool LooksLikePromptLeak(string src, string outp)
    {
        string[] markers = { "语音转写", "整理助手", "口癖", "改口", "保留最终说法",
                             "明显重复", "原样输出", "本说明", "ASR文本", "ASR)" };
        return markers.Any(m => outp.Contains(m) && !src.Contains(m));
    }

    /// <summary>Every ASCII English word in the source must appear in the output (case-insensitive).</summary>
    public static bool EnglishKept(string src, string outp) =>
        AsciiRuns(src.ToLowerInvariant(), char.IsLetter).IsSubsetOf(AsciiRuns(outp.ToLowerInvariant(), char.IsLetter));

    /// <summary>Every Arabic-digit run in the source must appear in the output.</summary>
    public static bool DigitsKept(string src, string outp) =>
        AsciiRuns(src, char.IsDigit).IsSubsetOf(AsciiRuns(outp, char.IsDigit));

    /// <summary>Contiguous runs of ASCII letters / digits.</summary>
    private static HashSet<string> AsciiRuns(string s, Func<char, bool> keep)
    {
        var set = new HashSet<string>();
        var cur = new StringBuilder();
        foreach (var ch in s)
        {
            if (ch < 128 && keep(ch)) cur.Append(ch);
            else if (cur.Length > 0) { set.Add(cur.ToString()); cur.Clear(); }
        }
        if (cur.Length > 0) set.Add(cur.ToString());
        return set;
    }
}
