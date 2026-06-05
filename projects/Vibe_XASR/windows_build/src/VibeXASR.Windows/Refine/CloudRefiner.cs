using System;
using System.Collections.Generic;
using System.Linq;
using System.Net.Http;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace VibeXASR.Windows.Refine;

// Cloud LLM refinement — backend + provider catalog + prompt assembly.
// Calls an OpenAI-compatible /chat/completions endpoint. Faithful port of macOS CloudRefiner.swift
// (cloud half of v2.0 AI 润色; the local llama.cpp half is intentionally NOT ported on Windows).

internal sealed class LlmModel
{
    public string Id { get; init; } = "";
    public string Label { get; init; } = "";
    public string Note { get; init; } = "";
    public LlmModel() { }
    public LlmModel(string id, string label, string note) { Id = id; Label = label; Note = note; }
}

internal sealed class LlmProvider
{
    public string Key { get; init; } = "";
    public string Label { get; init; } = "";
    public string Mark { get; init; } = "";          // 1–2 char logo glyph
    public string Cls { get; init; } = "";            // color class: "oa" green | "custom" purple | else blue
    public string Desc { get; init; } = "";
    public string BaseUrl { get; init; } = "";
    public string KeyHint { get; init; } = "";
    public string ModelLabel { get; init; } = "模型";
    public string DefaultModel { get; init; } = "";
    public LlmModel[] Models { get; init; } = Array.Empty<LlmModel>();
    public string Price { get; init; } = "";
}

/// <summary>Built-in OpenAI-compatible provider catalog (23 providers — see <see cref="CloudCatalog"/>).
/// The model field is free-text, so any provider/model works; the catalog supplies presets + defaults.</summary>
internal static class LlmProviders
{
    public static LlmProvider[] All => CloudCatalog.Providers;

    public static LlmProvider Find(string key) => All.FirstOrDefault(p => p.Key == key) ?? All[0];
    public static bool IsBuiltin(string key) => All.Any(p => p.Key == key);
}

/// <summary>The 4 processing toggles → the "auto" system prompt. Port of buildAutoPrompt.</summary>
internal static class CloudPrompt
{
    public static string BuildAuto(bool numbers, bool fillers, bool restate, bool hotwords)
    {
        var r = new List<string>();
        if (numbers) r.Add("• 数字规整:把口语数字转成阿拉伯数字(一百二十三 → 123、三点半 → 3:30、百分之二十 → 20%);成语、计数词保持不变。");
        if (fillers) r.Add("• 去口水词:删掉「嗯 / 呃 / 唉」等语气词和口吃式重复(那个那个 → 那个、我我我 → 我);正常叠词(看看 / 想想)保留。");
        if (restate) r.Add("• 改口纠正:说话人中途自我更正(常见「不对 / 不是 / 应该是 / 我还是…吧」等)时,必须删掉被否定、被替换掉的前半句,只保留最终说法;必要时把最终说法补成通顺完整的句子。例:「我想开发现代风格的客户端,不对,还是古早风格的吧」→「我想开发古早风格的客户端」。");
        if (hotwords) r.Add("• 热词修正:优先按热词表修正同音 / 近音误写,正确写法以热词表为准。\n  热词表:{{hotwords}}");
        var body = r.Count == 0 ? "•(暂未选择任何处理项,将原样返回文本)" : string.Join("\n", r);
        return "你是语音转写(ASR)的后处理助手。任务:把这段口述整理成说话人最终想表达的样子。只做下面已开启规则要求的增删,其余内容保持原样——不要改写用词、不要臆造或补充信息、不要总结、不要翻译。\n\n"
             + body
             + "\n\n【本地规则已做的改动 · 可能有误,请核对】\n下面是本机规则(同音字纠正 / 替换规则)对原始识别文本所做的修改;本地规则可能弄错,若发现改错了请改回正确写法,没问题则保持:\n{{changes}}\n\n只输出整理后的纯文本,不要解释、不要加引号。\n\n原文:{{transcript}}";
    }

    /// <summary>Fill {{hotwords}} / {{date}} / {{changes}}; leave {{transcript}} for the backend.</summary>
    public static string FillStatic(string tpl, string hotwords, string date, string changes = "(无)")
        => tpl.Replace("{{hotwords}}", string.IsNullOrEmpty(hotwords) ? "(无)" : hotwords)
              .Replace("{{date}}", date)
              .Replace("{{changes}}", string.IsNullOrEmpty(changes) ? "(无)" : changes);
}

/// <summary>Cloud backend: calls an OpenAI/Ark-compatible /chat/completions. Immutable → thread-safe.
/// Faithful port of macOS CloudRefiner.</summary>
internal sealed class CloudRefiner : IRefinerBackend
{
    private static readonly HttpClient Http = new() { Timeout = TimeSpan.FromSeconds(35) };

    public string BaseUrl { get; }
    public string Model { get; }
    public string ApiKey { get; }
    public double Temperature { get; }
    public int MaxTokens { get; }
    public string Provider { get; }

    public CloudRefiner(string baseUrl, string model, string apiKey, double temperature = 0.3,
                        int maxTokens = 2048, string provider = "")
    {
        BaseUrl = TrimUrl(baseUrl);
        Model = model;
        ApiKey = apiKey;
        Temperature = temperature;
        MaxTokens = maxTokens > 0 ? maxTokens : 2048;
        Provider = provider;
    }

    public bool IsReady => !string.IsNullOrEmpty(ApiKey) && !string.IsNullOrEmpty(BaseUrl) && !string.IsNullOrEmpty(Model);

    public async Task<string?> RefineAsync(string system, string text, CancellationToken ct)
    {
        var prompt = system.Contains("{{transcript}}")
            ? system.Replace("{{transcript}}", text)
            : system + "\n\n原文:" + text;
        var original = CloudRequestLog.Shared.PendingOriginal;
        var logInput = string.IsNullOrEmpty(original) ? text : original;

        // content over Max Tokens (output cap) → don't call (would be truncated); log + fall back.
        var estIn = EstimateTokens(text);
        if (estIn > MaxTokens)
        {
            CloudRequestLog.Shared.Record(Provider, BaseUrl, Model, "skipped", 0, logInput,
                $"内容约 {estIn} token,超过 Max Tokens({MaxTokens})。未调用模型,已回退规则版插入。请调大 Max Tokens,或缩短单次说话内容。", prompt);
            return null;
        }

        var sw = System.Diagnostics.Stopwatch.StartNew();
        try
        {
            var data = await ChatAsync(BaseUrl, Model, ApiKey,
                new[] { new Dictionary<string, string> { ["role"] = "user", ["content"] = prompt } },
                MaxTokens, Temperature, ct).ConfigureAwait(false);
            var ms = (int)sw.ElapsedMilliseconds;
            var outp = ExtractContent(data);
            CloudRequestLog.Shared.Record(Provider, BaseUrl, Model, outp is null ? "error" : "ok", ms,
                logInput, outp ?? "返回内容为空(无 choices/content)", prompt);
            return outp;
        }
        catch (Exception ex)
        {
            var ms = (int)sw.ElapsedMilliseconds;
            bool cancelled = ct.IsCancellationRequested || ex is OperationCanceledException || ex is TaskCanceledException;
            CloudRequestLog.Shared.Record(Provider, BaseUrl, Model, cancelled ? "timeout" : "error", ms,
                logInput, cancelled ? "超时取消(>润色超时)" : ex.Message, prompt);
            return null;
        }
    }

    // ----- shared HTTP -----

    private static string TrimUrl(string s)
    {
        var u = (s ?? "").Trim();
        while (u.EndsWith("/")) u = u.Substring(0, u.Length - 1);
        return u;
    }

    /// <summary>Rough token estimate: CJK ≈ 1/char, ASCII ≈ 0.3, else ≈ 0.7. For the over-cap pre-check.</summary>
    public static int EstimateTokens(string s)
    {
        double t = 0;
        foreach (var ch in s)
        {
            if ((ch >= 0x4E00 && ch <= 0x9FFF) || (ch >= 0x3040 && ch <= 0x30FF)) t += 1.0;
            else if (ch < 128) t += 0.3;
            else t += 0.7;
        }
        return (int)Math.Ceiling(t);
    }

    public static async Task<string> ChatAsync(string baseUrl, string model, string apiKey,
        IEnumerable<Dictionary<string, string>> messages, int maxTokens, double temperature, CancellationToken ct)
    {
        var url = TrimUrl(baseUrl) + "/chat/completions";
        var payload = JsonSerializer.Serialize(new
        {
            model,
            temperature,
            messages,
            max_tokens = maxTokens,
        });
        using var req = new HttpRequestMessage(HttpMethod.Post, url);
        req.Headers.TryAddWithoutValidation("Authorization", "Bearer " + apiKey);
        req.Content = new StringContent(payload, Encoding.UTF8, "application/json");
        using var resp = await Http.SendAsync(req, ct).ConfigureAwait(false);
        var data = await resp.Content.ReadAsStringAsync(ct).ConfigureAwait(false);
        if ((int)resp.StatusCode >= 400)
            throw new Exception(ExtractError(data) ?? $"HTTP {(int)resp.StatusCode}");
        return data;
    }

    public static string? ExtractContent(string data)
    {
        try
        {
            using var doc = JsonDocument.Parse(data);
            if (!doc.RootElement.TryGetProperty("choices", out var choices) || choices.GetArrayLength() == 0) return null;
            var msg = choices[0].GetProperty("message");
            if (!msg.TryGetProperty("content", out var content)) return null;
            return content.GetString()?.Trim();
        }
        catch { return null; }
    }

    public static string? ExtractError(string data)
    {
        try
        {
            using var doc = JsonDocument.Parse(data);
            var root = doc.RootElement;
            if (root.TryGetProperty("error", out var err) && err.TryGetProperty("message", out var m)) return m.GetString();
            if (root.TryGetProperty("message", out var m2)) return m2.GetString();
            return null;
        }
        catch { return null; }
    }

    /// <summary>Test connection + real round-trip. Returns (ok, ping ms, estimated added latency text, error).</summary>
    public static async Task<(bool ok, int ping, string add, string msg)> TestConnectionAsync(
        string baseUrl, string model, string apiKey)
    {
        if (string.IsNullOrWhiteSpace(apiKey)) return (false, 0, "", "缺少 API Key");
        var sw = System.Diagnostics.Stopwatch.StartNew();
        try
        {
            using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(30));
            _ = await ChatAsync(baseUrl, model, apiKey,
                new[] { new Dictionary<string, string> { ["role"] = "user", ["content"] = "hi" } },
                1, 0, cts.Token).ConfigureAwait(false);
            var ping = (int)sw.ElapsedMilliseconds;
            var rtt = ping / 1000.0;
            var add = $"{rtt + 1.0:0.0}–{rtt + 3.0:0.0}s";
            return (true, ping, add, "");
        }
        catch (Exception ex) { return (false, 0, "", ex.Message); }
    }
}
