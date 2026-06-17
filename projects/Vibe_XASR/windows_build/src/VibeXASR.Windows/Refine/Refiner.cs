using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace VibeXASR.Windows.Refine;

/// <summary>A refinement backend (cloud / local). Text in → polished out. Port of RefinerBackend.</summary>
internal interface IRefinerBackend
{
    /// <summary>Whether the backend is configured + ready. Not-ready → facade returns the input untouched.</summary>
    bool IsReady { get; }
    /// <summary>Refine the whole text once. Returns null when the backend can't handle it (caller falls back).</summary>
    Task<string?> RefineAsync(string system, string text, CancellationToken ct);
    /// <summary>Whether the backend appends an "uncertain words" list after the body — the CPM5 local model's
    /// self-report (`…&lt;KEY&gt;[词1、词2]`). The facade strips it before insert and relaxes the guardrails
    /// (CPM5 does its own ITN/改口, so the English/digit-kept checks would wrongly reject it). Cloud → false.</summary>
    bool EmitsUncertainList => false;
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

    /// <summary>CPM5(MiniCPM5-1B)官方固定 system prompt —— 开发者 corrector.py 原文,模型 SFT 即按此训练。
    /// 输出格式 <c>corrected_text&lt;KEY&gt;[词1、词2]</c>(&lt;KEY&gt; 后为不确定词,见 <see cref="StripUncertainList"/>)。
    /// ⚠️ 必须原样发送:不带它,模型走分布外退化路径(分隔符变 <c>&lt;font&gt;/&lt;center&gt;</c> 残渣、质量下降)。
    /// Used only by the LOCAL backend (set as SystemProvider when LocalRefiner is active).</summary>
    public const string CpmSystemPrompt =
        "你是流式ASR后处理助手。输入ASR原始识别文本，输出修正后的规范文本。" +
        "去口癖、纠错字、加标点，规范书写格式，" +
        "保留全部语义不捏造。不确定的词在末尾标注<KEY>[词1、词2]。" +
        "直接输出结果，不要解释。";

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
        if (backend.EmitsUncertainList) outp = StripUncertainList(outp);   // CPM5: drop the tail list, never insert it
        if (string.IsNullOrEmpty(outp) || !Guardrails.Accept(text, outp, backend.EmitsUncertainList)) return text;  // guardrail reject → fall back
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

    /// <summary>Strip the "uncertain words" list the CPM5 model appends after the body, keeping only the body.
    /// Official format (with the fixed CPM5 system prompt) is <c>corrected_text&lt;KEY&gt;[词1、词2]</c> — split on
    /// <c>&lt;KEY&gt;</c>. Fallback: a quantized output may drop <c>&lt;KEY&gt;</c> and leave a trailing <c>&lt;…&gt;</c>
    /// block (out-of-distribution); strip a short trailing <c>&lt;…</c> block too (speech bodies rarely contain '&lt;',
    /// so the false-positive risk is tiny). Port of macOS Refiner.stripUncertainList.</summary>
    public const string UncertainKeySep = "<KEY>";
    public static string StripUncertainList(string s)
    {
        int i = s.IndexOf(UncertainKeySep, StringComparison.Ordinal);
        if (i >= 0) return s.Substring(0, i).Trim();
        var m = System.Text.RegularExpressions.Regex.Match(s, @"\s*<[^<\n]{0,100}$");
        return m.Success ? s.Substring(0, m.Index).Trim() : s;
    }
}

/// <summary>Guardrails: prevent the refiner from losing info / mangling. Any reject → caller falls back.
/// Faithful port of macOS Guardrails. Pure logic.</summary>
internal static class Guardrails
{
    /// <summary>Output shorter than the source by more than this ratio → "deleted too much" reject. A genuine
    /// restatement can legitimately drop the first half (~60% measured), so 0.7 only catches extreme loss.</summary>
    public const double MaxShrink = 0.7;

    /// <param name="loose">CPM5/local: the model actively does ITN (forty two→42, 一百二十三→123) + 改口, so the
    /// mechanical "keep every English/digit run" checks would wrongly reject these legitimate rewrites. macOS
    /// drops them for CPM5 and keeps only ① prompt-leak ② length-collapse. Cloud (strict) keeps all four.</param>
    public static bool Accept(string src, string outp, bool loose = false)
    {
        if (LooksLikePromptLeak(src, outp)) return false;       // model parroted the instruction → reject
        if (!loose)
        {
            if (!EnglishKept(src, outp)) return false;          // every English word must survive
            if (!DigitsKept(src, outp)) return false;           // every Arabic-digit run must survive
        }
        var shrink = 1.0 - (double)outp.Length / Math.Max(src.Length, 1);
        return shrink <= MaxShrink;                             // length-collapse backstop
    }

    /// <summary>Prompt-leak detection: small models sometimes echo the system instruction into the output.
    /// Output contains an instruction marker that the source did not → treat as leak, fall back.
    /// Covers both the cloud rule-prompt markers and the CPM5 local-prompt markers (harmless to check both).</summary>
    public static bool LooksLikePromptLeak(string src, string outp)
    {
        string[] markers = { "语音转写", "整理助手", "口癖", "改口", "保留最终说法",
                             "明显重复", "原样输出", "本说明", "ASR文本", "ASR)",
                             // CPM5 local-prompt markers (port of macOS Guardrails)
                             "流式ASR", "后处理助手", "ASR原始", "纠错字", "不捏造",
                             "标注<KEY>", "直接输出结果", "不要解释" };
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
