using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Sockets;
using System.Reflection;
using System.Text;
using System.Text.Encodings.Web;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using VibeXASR.Windows.Lexicon;
using VibeXASR.Windows.Storage;

namespace VibeXASR.Windows.Sharing;

/// <summary>
/// Local share API (共享): a minimal embedded read-only HTTP/1.1 server that lets the user's own
/// coding agents (Claude Code / Codex / OpenClaw …) read their on-device dictation data + dictionary.
/// Raw <see cref="TcpListener"/> (no admin / urlacl needed), GET-only, bearer-key auth on EVERY
/// request, bound to 127.0.0.1 unless the user explicitly allows LAN. Off by default. Nothing here
/// ever reaches the internet. Faithful port of macOS LocalAPIServer.swift.
/// </summary>
public sealed class LocalApiServer
{
    private readonly Settings _settings;
    private readonly HistoryStore _history;
    private TcpListener? _listener;
    private CancellationTokenSource? _cts;

    public bool IsRunning { get; private set; }
    public int BoundPort { get; private set; }

    private static readonly JsonSerializerOptions JsonOpts = new()
    {
        WriteIndented = true,
        Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
    };

    public LocalApiServer(Settings settings, HistoryStore history)
    {
        _settings = settings;
        _history = history;
    }

    /// <summary>(Re)start to match settings (stops first). If the chosen port is busy it advances to
    /// the next ports and binds the first free one; <see cref="BoundPort"/> reflects what bound.</summary>
    public void Restart(bool enabled, int port, bool allowLAN)
    {
        Stop();
        if (!enabled || port <= 0) return;
        var addr = allowLAN ? IPAddress.Any : IPAddress.Loopback;
        for (int i = 0; i < 12; i++)
        {
            try
            {
                var l = new TcpListener(addr, port + i);
                l.Start();
                _listener = l; BoundPort = port + i; IsRunning = true;
                _cts = new CancellationTokenSource();
                _ = AcceptLoop(l, _cts.Token);
                Diag.Log($"api: listening on {(allowLAN ? "0.0.0.0" : "127.0.0.1")}:{BoundPort}");
                return;
            }
            catch (SocketException) { /* port busy → try the next */ }
        }
        Diag.Log("api: could not bind any port");
    }

    public void Stop()
    {
        try { _cts?.Cancel(); } catch { }
        try { _listener?.Stop(); } catch { }
        _listener = null; _cts = null; IsRunning = false; BoundPort = 0;
    }

    private async Task AcceptLoop(TcpListener l, CancellationToken ct)
    {
        while (!ct.IsCancellationRequested)
        {
            TcpClient client;
            try { client = await l.AcceptTcpClientAsync(ct); }
            catch { break; }
            _ = HandleClient(client);
        }
    }

    private async Task HandleClient(TcpClient client)
    {
        try
        {
            using (client)
            {
                using var stream = client.GetStream();
                var head = await ReadHead(stream);
                var resp = head is null ? Response.Text(400, "bad request") : Route(new Request(head));
                var bytes = resp.ToHttp();
                await stream.WriteAsync(bytes);
                await stream.FlushAsync();
            }
        }
        catch { /* best-effort: a dropped connection must never break the app */ }
    }

    /// <summary>Read until the end of the HTTP header block (GET requests carry no body).</summary>
    private static async Task<string?> ReadHead(NetworkStream stream)
    {
        using var buf = new MemoryStream();
        var chunk = new byte[4096];
        while (buf.Length < 256 * 1024)
        {
            int n;
            try { n = await stream.ReadAsync(chunk); } catch { return null; }
            if (n <= 0) break;
            buf.Write(chunk, 0, n);
            var arr = buf.GetBuffer();
            int len = (int)buf.Length;
            for (int i = 3; i < len; i++)
                if (arr[i] == '\n' && arr[i - 1] == '\r' && arr[i - 2] == '\n' && arr[i - 3] == '\r')
                    return Encoding.UTF8.GetString(arr, 0, i - 3);
        }
        return null;
    }

    // ----- routing (reads the live Settings + HistoryStore) -----

    private Response Route(Request req)
    {
        if (req.Bearer != _settings.ApiKey)
            return Response.Json(401, new Dictionary<string, object>
            {
                ["error"] = "unauthorized",
                ["hint"] = "pass ?key=<key> or header 'Authorization: Bearer <key>'",
            });

        switch (req.Path)
        {
            case "/":
            case "/v1/ping":
                return Response.Json(200, new Dictionary<string, object>
                {
                    ["ok"] = true, ["app"] = "Vibe XASR", ["version"] = AppVersion(),
                    ["endpoints"] = new[] { "/v1/history", "/v1/export", "/v1/config/hotwords",
                                            "/v1/config/replacements", "/v1/config/snippets", "/skill" },
                });
            case "/v1/history":
            {
                var items = Filtered(req);
                return Response.Json(200, new Dictionary<string, object>
                {
                    ["count"] = items.Count,
                    ["items"] = items.Select(EntryJson).ToList(),
                });
            }
            case "/v1/export":
                return Export(req);
            case "/v1/config/hotwords":
                return Response.Json(200, new Dictionary<string, object>
                {
                    ["enabled"] = _settings.HotwordsEnabled,
                    ["score"] = _settings.HotwordsScore,
                    ["words"] = (_settings.HotwordsText ?? "").Split('\n', '\r').Select(s => s.Trim()).Where(s => s.Length > 0).ToList(),
                });
            case "/v1/config/replacements":
                return Response.Json(200, new Dictionary<string, object>
                {
                    ["enabled"] = _settings.ReplacementsEnabled,
                    ["rules"] = Replacements.Parse(_settings.ReplacementsText)
                        .Select(r => new Dictionary<string, string> { ["from"] = r.From, ["to"] = r.To }).ToList(),
                });
            case "/v1/config/snippets":
                return Response.Json(200, new Dictionary<string, object>
                {
                    ["enabled"] = _settings.SnippetsEnabled,
                    ["snippets"] = SnippetList(_settings.SnippetsJson),
                });
            case "/skill":
            case "/skill.md":
                return Response.Text(200, SkillMarkdown(req.BaseUrl, _settings.ApiKey), "text/markdown; charset=utf-8");
            default:
                return Response.Json(404, new Dictionary<string, object> { ["error"] = "not found", ["path"] = req.Path });
        }
    }

    private Response Export(Request req)
    {
        var asc = Filtered(req).OrderBy(e => e.Timestamp).ToList();
        if ((req.Query.GetValueOrDefault("format") ?? "md") == "txt")
        {
            var body = string.Join("\n", asc.Select(e => $"{e.Timestamp.LocalDateTime:HH:mm}  {e.Text}"));
            return Response.Text(200, body.Length == 0 ? "(无记录)" : body);
        }
        var md = new StringBuilder("# Vibe XASR 记录导出\n\n");
        string lastDay = "";
        foreach (var e in asc)
        {
            var day = e.Timestamp.LocalDateTime.ToString("yyyy年M月d日 dddd", new System.Globalization.CultureInfo("zh-CN"));
            if (day != lastDay) { md.Append($"\n## {day}\n\n"); lastDay = day; }
            if (!string.IsNullOrEmpty(e.Title)) md.Append($"**{e.Title}**\n");
            md.Append($"- {e.Timestamp.LocalDateTime:HH:mm}　{e.Text}\n");
        }
        if (asc.Count == 0) md.Append("_(该范围内没有记录)_\n");
        return Response.Text(200, md.ToString(), "text/markdown; charset=utf-8");
    }

    /// <summary>Apply ?date / ?from&amp;to / ?limit filters to the (newest-first) history.</summary>
    private List<HistoryEntry> Filtered(Request req)
    {
        var items = _history.List().ToList();   // newest-first
        if (req.Query.TryGetValue("date", out var ds))
        {
            var (s0, e0) = DayRange(ds);
            if (s0 != default) items = items.Where(e => e.Timestamp >= s0 && e.Timestamp < e0).ToList();
        }
        else if (req.Query.TryGetValue("from", out var f) && req.Query.TryGetValue("to", out var t))
        {
            var (fs, _) = DayRange(f);
            var (_, te) = DayRange(t);
            if (fs != default && te != default) items = items.Where(e => e.Timestamp >= fs && e.Timestamp < te).ToList();
        }
        if (req.Query.TryGetValue("limit", out var lim) && int.TryParse(lim, out var nlim) && nlim > 0)
            items = items.Take(nlim).ToList();
        return items;
    }

    private static Dictionary<string, object> EntryJson(HistoryEntry e)
    {
        var d = new Dictionary<string, object>
        {
            ["text"] = e.Text,
            ["date"] = e.Timestamp.ToString("o"),   // ISO-8601
            ["mode"] = e.Mode,
        };
        if (!string.IsNullOrEmpty(e.Title)) d["title"] = e.Title!;
        if (e.Tags.Count > 0) d["tags"] = e.Tags;
        return d;
    }

    private static List<Dictionary<string, string>> SnippetList(string? json)
    {
        var list = new List<Dictionary<string, string>>();
        if (string.IsNullOrWhiteSpace(json)) return list;
        try
        {
            using var doc = JsonDocument.Parse(json);
            if (doc.RootElement.ValueKind != JsonValueKind.Array) return list;
            foreach (var el in doc.RootElement.EnumerateArray())
            {
                var t = el.TryGetProperty("t", out var tv) ? tv.GetString() : null;
                var x = el.TryGetProperty("x", out var xv) ? xv.GetString() : null;
                if (!string.IsNullOrEmpty(t)) list.Add(new() { ["trigger"] = t!, ["text"] = x ?? "" });
            }
        }
        catch { }
        return list;
    }

    /// <summary>"today" / "yesterday" / "yyyy-MM-dd" → [startOfDay, nextDay). default tuple on miss.</summary>
    private static (DateTimeOffset, DateTimeOffset) DayRange(string s)
    {
        DateTime? day = s.ToLowerInvariant() switch
        {
            "today" => DateTime.Today,
            "yesterday" => DateTime.Today.AddDays(-1),
            _ => DateTime.TryParseExact(s, "yyyy-MM-dd", System.Globalization.CultureInfo.InvariantCulture,
                    System.Globalization.DateTimeStyles.None, out var d) ? d.Date : (DateTime?)null,
        };
        if (day is not { } dd) return (default, default);
        var start = new DateTimeOffset(DateTime.SpecifyKind(dd, DateTimeKind.Unspecified), DateTimeOffset.Now.Offset);
        return (start, start.AddDays(1));
    }

    private static string AppVersion()
    {
        var v = Assembly.GetExecutingAssembly().GetName().Version ?? new Version(1, 4, 0);
        return $"{v.Major}.{v.Minor}.{Math.Max(0, v.Build)}";
    }

    // ----- HTTP request / response value types -----

    private sealed class Request
    {
        public string Method { get; }
        public string Path { get; }
        public Dictionary<string, string> Query { get; } = new();
        public Dictionary<string, string> Headers { get; } = new();

        public Request(string head)
        {
            var lines = head.Split("\r\n");
            var parts = lines.Length > 0 ? lines[0].Split(' ') : Array.Empty<string>();
            Method = parts.Length > 0 ? parts[0] : "GET";
            var raw = parts.Length > 1 ? parts[1] : "/";
            int q = raw.IndexOf('?');
            if (q >= 0) { Path = raw[..q]; ParseQuery(raw[(q + 1)..]); } else Path = raw;
            foreach (var line in lines.Skip(1))
            {
                int c = line.IndexOf(':');
                if (c < 0) continue;
                Headers[line[..c].Trim().ToLowerInvariant()] = line[(c + 1)..].Trim();
            }
        }

        private void ParseQuery(string s)
        {
            foreach (var pair in s.Split('&', StringSplitOptions.RemoveEmptyEntries))
            {
                int eq = pair.IndexOf('=');
                var k = Uri.UnescapeDataString(eq >= 0 ? pair[..eq] : pair);
                var v = eq >= 0 ? Uri.UnescapeDataString(pair[(eq + 1)..]) : "";
                Query[k] = v;
            }
        }

        public string? Bearer
        {
            get
            {
                if (Headers.TryGetValue("authorization", out var a) && a.StartsWith("bearer ", StringComparison.OrdinalIgnoreCase))
                    return a[7..].Trim();
                return Query.GetValueOrDefault("key");
            }
        }

        public string BaseUrl => Headers.TryGetValue("host", out var h) && h.Length > 0 ? $"http://{h}" : "http://127.0.0.1:8473";
    }

    private sealed class Response
    {
        public int Status;
        public string ContentType = "text/plain; charset=utf-8";
        public byte[] Body = Array.Empty<byte>();

        public static Response Json(int status, object obj) => new()
        {
            Status = status,
            ContentType = "application/json; charset=utf-8",
            Body = Encoding.UTF8.GetBytes(JsonSerializer.Serialize(obj, JsonOpts)),
        };
        public static Response Text(int status, string s, string type = "text/plain; charset=utf-8") => new()
        {
            Status = status, ContentType = type, Body = Encoding.UTF8.GetBytes(s),
        };

        public byte[] ToHttp()
        {
            var reason = Status switch { 200 => "OK", 400 => "Bad Request", 401 => "Unauthorized", 404 => "Not Found", _ => "OK" };
            var head = $"HTTP/1.1 {Status} {reason}\r\n" +
                       $"Content-Type: {ContentType}\r\n" +
                       $"Content-Length: {Body.Length}\r\n" +
                       "Access-Control-Allow-Origin: *\r\n" +
                       "Connection: close\r\n\r\n";
            return Encoding.UTF8.GetBytes(head).Concat(Body).ToArray();
        }
    }

    // ----- skill document served at /skill (pasted into an agent's skills dir) -----

    private static string SkillMarkdown(string baseUrl, string key) => $$"""
        # Vibe XASR — 本地语音记录 / 词典接入

        通过 Vibe XASR 在本机暴露的只读 HTTP API,读取用户的**语音听写记录**、**词典(热词/替换)**、**口令**,
        以便在当前编程助手里接续工作(例如把今天口述的需求导出后继续实现)。

        - Base URL: `{{baseUrl}}`
        - 鉴权:每个请求都要带 key(二选一):
          - 头部 `Authorization: Bearer {{key}}`
          - 或查询参数 `?key={{key}}`
        - 全部为 **GET / 只读**;数据仅在本机,默认只监听 127.0.0.1。

        ## 接口
        | 用途 | 请求 |
        |---|---|
        | 健康检查 | `GET /v1/ping` |
        | 全部记录(最新在前) | `GET /v1/history` |
        | 指定某天 | `GET /v1/history?date=today`(或 `yesterday` / `2026-06-03`) |
        | 日期区间 | `GET /v1/history?from=2026-06-01&to=2026-06-03` |
        | 导出成稿(Markdown) | `GET /v1/export?date=today&format=md` |
        | 导出成稿(纯文本) | `GET /v1/export?date=today&format=txt` |
        | 词典·热词 | `GET /v1/config/hotwords` |
        | 词典·替换 | `GET /v1/config/replacements` |
        | 口令 | `GET /v1/config/snippets` |

        ## 示例
        ```bash
        curl -s -H "Authorization: Bearer {{key}}" "{{baseUrl}}/v1/export?date=today&format=md"
        curl -s "{{baseUrl}}/v1/config/hotwords?key={{key}}"
        ```

        ## 说明
        - 401 = key 不对或缺失。
        - 若连接被拒:请确认用户在 Vibe XASR「共享」里开启了服务;局域网访问需用户单独允许。
        """;
}
