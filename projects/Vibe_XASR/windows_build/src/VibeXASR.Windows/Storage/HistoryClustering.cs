using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;

namespace VibeXASR.Windows.Storage;

/// <summary>
/// History clustering / grouping — pure, deterministic logic (no UI). Faithful port of the macOS
/// <c>HistoryClustering.swift</c> (itself a port of the design prototype's app.jsx / calendar.jsx):
/// day grouping, fragment clustering by pause-gap or cumulative chars, OnCall run folding, and
/// calendar/heatmap helpers. Drives the redesigned 记录 workspace.
/// </summary>
public static class HistoryClustering
{
    /// <summary>Visible character count (whitespace stripped); CJK each count 1.</summary>
    public static int CharCount(string? s)
    {
        if (string.IsNullOrEmpty(s)) return 0;
        int n = 0;
        foreach (var c in s) if (!char.IsWhiteSpace(c)) n++;
        return n;
    }

    /// <summary>Local "Y-M-D" key (month/day NOT zero-padded), matching the prototype's dayKey.</summary>
    public static string DayKey(DateTimeOffset date)
    {
        var d = date.LocalDateTime;
        return $"{d.Year}-{d.Month}-{d.Day}";
    }

    public enum AggMode { Pause, Chars }

    public sealed class AggOptions
    {
        public AggMode Mode = AggMode.Pause;
        public double GapSeconds = 120;     // pause threshold
        public int TargetChars = 120;       // chars-mode paragraph target
        /// <summary>Chars-mode never bridges a gap longer than this (the prototype's 15-min hard break).</summary>
        public const double HardBreakSeconds = 15 * 60;
    }

    public enum HNodeKind { Single, Cluster, OnCall }

    /// <summary>A display node: a lone fragment, a cluster of consecutive fragments, or a folded
    /// run of consecutive OnCall blocks. <see cref="Items"/> are ASCENDING by date.</summary>
    public sealed class HNode
    {
        public HNodeKind Kind { get; init; }
        public List<HistoryEntry> Items { get; init; } = new();
        public string Id => Kind switch
        {
            HNodeKind.Single => "s-" + Items[0].Id,
            HNodeKind.Cluster => "cl-" + (Items.Count > 0 ? Items[0].Id.ToString() : ""),
            _ => "oc-" + (Items.Count > 0 ? Items[0].Id.ToString() : ""),
        };
    }

    public sealed class DayGroup
    {
        public string Key { get; init; } = "";
        public DateTimeOffset Date { get; init; }   // representative ts (newest in the day)
        public List<HNode> Nodes { get; init; } = new();   // newest-first for display
        public int Count { get; init; }
    }

    public sealed class Filters
    {
        public bool ShowOnCall = true;
        public string? TagFilter;
        public string Query = "";
        public string? SelectedDay;
        public bool Aggregate = true;
        public AggOptions Opts = new();
    }

    /// <summary>Subdivide a run of consecutive non-OnCall fragments (ASC by date) by the rule.</summary>
    private static List<List<HistoryEntry>> Subdivide(List<HistoryEntry> run, AggOptions o)
    {
        var subs = new List<List<HistoryEntry>>();
        if (run.Count < 2) { subs.Add(run); return subs; }
        if (o.Mode == AggMode.Chars)
        {
            var cur = new List<HistoryEntry>(); int sum = 0;
            for (int k = 0; k < run.Count; k++)
            {
                bool big = k > 0 && (run[k].Timestamp - run[k - 1].Timestamp).TotalSeconds > AggOptions.HardBreakSeconds;
                if (big && cur.Count > 0) { subs.Add(cur); cur = new(); sum = 0; }
                cur.Add(run[k]); sum += CharCount(run[k].Text);
                if (sum >= o.TargetChars) { subs.Add(cur); cur = new(); sum = 0; }
            }
            if (cur.Count > 0) subs.Add(cur);
        }
        else
        {
            var cur = new List<HistoryEntry> { run[0] };
            for (int k = 1; k < run.Count; k++)
            {
                if ((run[k].Timestamp - run[k - 1].Timestamp).TotalSeconds <= o.GapSeconds) cur.Add(run[k]);
                else { subs.Add(cur); cur = new() { run[k] }; }
            }
            subs.Add(cur);
        }
        return subs;
    }

    /// <summary>Turn a day's ASC entries into display nodes (OnCall runs folded; non-OnCall runs
    /// subdivided into clusters when aggregating).</summary>
    private static List<HNode> Clusterize(List<HistoryEntry> asc, bool aggregate, AggOptions o)
    {
        var nodes = new List<HNode>();
        int i = 0;
        while (i < asc.Count)
        {
            if (asc[i].Mode == "oncall")
            {
                int j = i; var arr = new List<HistoryEntry>();
                while (j < asc.Count && asc[j].Mode == "oncall") { arr.Add(asc[j]); j++; }
                nodes.Add(new HNode { Kind = HNodeKind.OnCall, Items = arr }); i = j; continue;
            }
            int k = i; var run = new List<HistoryEntry>();
            while (k < asc.Count && asc[k].Mode != "oncall") { run.Add(asc[k]); k++; }
            i = k;
            if (!aggregate) { foreach (var e in run) nodes.Add(new HNode { Kind = HNodeKind.Single, Items = new() { e } }); continue; }
            foreach (var arr in Subdivide(run, o))
            {
                if (arr.Count >= 2) nodes.Add(new HNode { Kind = HNodeKind.Cluster, Items = arr });
                else foreach (var e in arr) nodes.Add(new HNode { Kind = HNodeKind.Single, Items = new() { e } });
            }
        }
        return nodes;
    }

    /// <summary>Filter → group by day (newest first) → clusterize each day → newest-first nodes.</summary>
    public static List<DayGroup> BuildGroups(IReadOnlyList<HistoryEntry> entries, Filters f)
    {
        var q = f.Query.Trim();
        var items = entries.Where(e =>
        {
            if (!f.ShowOnCall && e.Mode == "oncall") return false;
            if (f.TagFilter is { } tf && !e.Tags.Contains(tf)) return false;
            if (q.Length > 0)
            {
                bool inText = e.Text.Contains(q, StringComparison.OrdinalIgnoreCase);
                bool inTitle = e.Title?.Contains(q, StringComparison.OrdinalIgnoreCase) ?? false;
                bool inTags = e.Tags.Any(t => t.Contains(q, StringComparison.OrdinalIgnoreCase));
                if (!(inText || inTitle || inTags)) return false;
            }
            if (f.SelectedDay is { } sd && DayKey(e.Timestamp) != sd) return false;
            return true;
        }).ToList();

        // group by day, preserving first-seen order (entries arrive newest-first)
        var byDay = new Dictionary<string, List<HistoryEntry>>();
        var order = new List<string>();
        foreach (var e in items)
        {
            var k = DayKey(e.Timestamp);
            if (!byDay.TryGetValue(k, out var list)) { list = new(); byDay[k] = list; order.Add(k); }
            list.Add(e);
        }
        var keys = order.OrderByDescending(k => byDay[k].Count > 0 ? byDay[k][0].Timestamp : DateTimeOffset.MinValue).ToList();
        return keys.Select(k =>
        {
            var day = byDay[k];
            var asc = day.OrderBy(e => e.Timestamp).ToList();
            var nodes = Clusterize(asc, f.Aggregate, f.Opts);
            nodes.Reverse();   // newest-first for display
            return new DayGroup { Key = k, Date = day.Count > 0 ? day[0].Timestamp : DateTimeOffset.Now, Nodes = nodes, Count = day.Count };
        }).ToList();
    }

    /// <summary>6×7 (=42) Monday-first grid of dates covering the month containing <paramref name="cursor"/>.</summary>
    public static List<DateTime> MonthGrid(DateTime cursor)
    {
        var first = new DateTime(cursor.Year, cursor.Month, 1);
        int weekday = (int)first.DayOfWeek;      // 0=Sun … 6=Sat
        int lead = (weekday + 6) % 7;            // Monday-first lead
        var start = first.AddDays(-lead);
        return Enumerable.Range(0, 42).Select(i => start.AddDays(i)).ToList();
    }

    /// <summary>Heatmap intensity 0–4 from a day's count vs the month max.</summary>
    public static int HeatLevel(int n, int max)
    {
        if (n <= 0) return 0;
        double r = (double)n / Math.Max(1, max);
        if (r > 0.66) return 4;
        if (r > 0.40) return 3;
        if (r > 0.15) return 2;
        return 1;
    }
}
