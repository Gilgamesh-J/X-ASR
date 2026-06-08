using System;
using System.Collections.Generic;
using System.Linq;
using System.Text.Json;

namespace VibeXASR.Windows.Refine;

// Cloud-refine UI data: prompt templates, custom providers, named profiles + JSON helpers + seeds.
// Faithful port of macOS CloudConfig.swift (the parts the Windows tab needs).

internal sealed class CloudTemplate
{
    public string Id { get; set; } = "";
    public string Name { get; set; } = "";
    public string Content { get; set; } = "";
}

internal sealed class CloudCustomProvider
{
    public string Id { get; set; } = "";
    public string Label { get; set; } = "";
    public string BaseURL { get; set; } = "";
}

/// <summary>A saved named cloud config (one-tap switch). The API key is NOT stored here — it lives in
/// SecretStore under "cloud_profile_&lt;id&gt;" so it stays DPAPI-encrypted, never in settings.json.</summary>
internal sealed class CloudProfile
{
    public string Id { get; set; } = "";
    public string Name { get; set; } = "";
    public string Provider { get; set; } = "";
    public string BaseURL { get; set; } = "";
    public string Model { get; set; } = "";
    public double Temperature { get; set; } = 0.3;
    public int MaxTokens { get; set; } = 2048;
    public bool Numbers { get; set; } = true;
    public bool Fillers { get; set; } = true;
    public bool Restate { get; set; } = true;
    public bool Hotwords { get; set; } = true;
    public string ActiveTemplate { get; set; } = "auto";
    public string AutoOverride { get; set; } = "";
}

internal static class CloudJson
{
    private static readonly JsonSerializerOptions Opts = new() { PropertyNameCaseInsensitive = true };

    public static List<CloudTemplate> Templates(string? json)
    {
        if (string.IsNullOrWhiteSpace(json)) return Clone(CloudSeeds.Templates);
        try
        {
            var a = JsonSerializer.Deserialize<List<CloudTemplate>>(json!, Opts);
            return a is { Count: > 0 } ? a : Clone(CloudSeeds.Templates);
        }
        catch { return Clone(CloudSeeds.Templates); }
    }
    public static List<CloudCustomProvider> CustomProviders(string? json)
    {
        if (string.IsNullOrWhiteSpace(json)) return new();
        try { return JsonSerializer.Deserialize<List<CloudCustomProvider>>(json!, Opts) ?? new(); }
        catch { return new(); }
    }
    public static List<CloudProfile> Profiles(string? json)
    {
        if (string.IsNullOrWhiteSpace(json)) return new();
        try { return JsonSerializer.Deserialize<List<CloudProfile>>(json!, Opts) ?? new(); }
        catch { return new(); }
    }
    public static string Encode<T>(IEnumerable<T> list) => JsonSerializer.Serialize(list);

    private static List<CloudTemplate> Clone(List<CloudTemplate> src) =>
        src.Select(t => new CloudTemplate { Id = t.Id, Name = t.Name, Content = t.Content }).ToList();
}

/// <summary>Per-template hotkey bindings (Prompt Studio): JSON {"templateId":{"vk":88,"mods":3}}.</summary>
internal static class CloudTemplateHotkeys
{
    public static List<(string Id, int Vk, int Mods)> Parse(string? json)
    {
        var list = new List<(string, int, int)>();
        if (string.IsNullOrWhiteSpace(json)) return list;
        try
        {
            using var doc = JsonDocument.Parse(json!);
            if (doc.RootElement.ValueKind != JsonValueKind.Object) return list;
            foreach (var p in doc.RootElement.EnumerateObject())
            {
                if (p.Value.ValueKind != JsonValueKind.Object) continue;
                int vk = p.Value.TryGetProperty("vk", out var v) && v.TryGetInt32(out var vi) ? vi : 0;
                int mods = p.Value.TryGetProperty("mods", out var m) && m.TryGetInt32(out var mi) ? mi : 0;
                if (vk != 0) list.Add((p.Name, vk, mods));
            }
        }
        catch { }
        return list;
    }

    public static (int Vk, int Mods) For(string? json, string id)
    {
        foreach (var (i, vk, mods) in Parse(json)) if (i == id) return (vk, mods);
        return (0, 0);
    }

    public static string Set(string? json, string id, int vk, int mods)
    {
        var map = Parse(json).Where(b => b.Id != id).ToList();
        if (vk != 0) map.Add((id, vk, mods));
        var d = new Dictionary<string, Dictionary<string, int>>();
        foreach (var (i, v, m) in map) d[i] = new() { ["vk"] = v, ["mods"] = m };
        return JsonSerializer.Serialize(d);
    }
}

internal static class CloudSeeds
{
    public static readonly List<CloudTemplate> Templates = new()
    {
        new() { Id = "t1", Name = "口语转书面",
            Content = "把下面这段口述整理成通顺的书面表达,保留全部信息和原意,不要总结、不要遗漏。\n• 去掉口水词与重复,规整数字写法。\n• 专有名词以热词表为准:{{hotwords}}\n\n只输出整理后的文本。\n\n原文:{{transcript}}" },
        new() { Id = "t2", Name = "会议纪要",
            Content = "把下面的会议口述整理成结构化纪要:\n1)一句话主题;\n2)关键结论(要点列表);\n3)待办事项(负责人 + 事项)。\n专有名词以热词表为准:{{hotwords}}\n\n会议转写:{{transcript}}" },
        new() { Id = "t3", Name = "本地纠错复核",
            Content = "你是语音转写后处理助手。下面给出原始识别文本,以及本机规则(同音字纠正 / 替换规则)已做的改动。请在保持原意、不增删信息的前提下整理文本,并重点核对本地规则的改动——若改错了请改回正确写法,没问题则保持。\n\n本地规则改动(可能有误):\n{{changes}}\n\n专有名词以热词表为准:{{hotwords}}\n\n只输出整理后的纯文本,不要解释、不要加引号。\n\n原文:{{transcript}}" },
    };

    public static readonly (string Token, string Desc)[] Tokens =
    {
        ("{{transcript}}", "转写原文"), ("{{hotwords}}", "词典热词"),
        ("{{date}}", "当前日期"), ("{{changes}}", "本地规则改动"),
    };
}
