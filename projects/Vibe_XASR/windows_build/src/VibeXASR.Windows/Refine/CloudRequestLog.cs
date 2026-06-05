using System;
using System.Collections.Generic;

namespace VibeXASR.Windows.Refine;

/// <summary>One "recent request" record (troubleshooting + one-tap issue). Port of CloudRequestLog.Entry.</summary>
internal sealed class CloudReqEntry
{
    public Guid Id { get; } = Guid.NewGuid();
    public DateTime At { get; init; }
    public string Provider { get; init; } = "";
    public string BaseUrl { get; init; } = "";
    public string Model { get; init; } = "";
    public string Status { get; init; } = "";   // "ok" | "timeout" | "error" | "skipped"
    public int Ms { get; init; }
    public string Input { get; init; } = "";     // text sent to the model (original ASR)
    public string Output { get; init; } = "";    // model reply (or error message)
    public string Prompt { get; init; } = "";    // the actual prompt sent (placeholders filled)
}

/// <summary>Ring buffer of recent cloud-refine requests, for the settings page. Thread-safe: the refiner
/// writes from a background task, the UI reads on the UI thread. Keeps the latest 20. Port of CloudRequestLog.</summary>
internal sealed class CloudRequestLog
{
    public static readonly CloudRequestLog Shared = new();

    private readonly object _lock = new();
    private readonly List<CloudReqEntry> _entries = new();
    private const int Cap = 20;
    private bool _enabled = true;
    private string _pendingOriginal = "";

    /// <summary>Whether to record (user can turn off). Thread-safe.</summary>
    public bool Enabled
    {
        get { lock (_lock) return _enabled; }
        set { lock (_lock) _enabled = value; }
    }

    /// <summary>The raw ASR output (no pinyin/replacement/defiller — engine raw) used as the next record's
    /// input. TrayApp sets it before each refine; CloudRefiner reads it when logging.</summary>
    public string PendingOriginal
    {
        get { lock (_lock) return _pendingOriginal; }
        set { lock (_lock) _pendingOriginal = value; }
    }

    private static string Clip(string s, int n) => s.Length > n ? s.Substring(0, n) + "…" : s;

    public void Record(string provider, string baseUrl, string model, string status, int ms,
                       string input, string output, string prompt)
    {
        var e = new CloudReqEntry
        {
            At = DateTime.Now, Provider = provider, BaseUrl = baseUrl, Model = model, Status = status, Ms = ms,
            Input = Clip(input, 4000), Output = Clip(output, 4000), Prompt = Clip(prompt, 6000),
        };
        lock (_lock)
        {
            if (!_enabled) return;
            _entries.Insert(0, e);
            if (_entries.Count > Cap) _entries.RemoveRange(Cap, _entries.Count - Cap);
        }
    }

    public List<CloudReqEntry> Snapshot() { lock (_lock) return new List<CloudReqEntry>(_entries); }
    public void Clear() { lock (_lock) _entries.Clear(); }
}
