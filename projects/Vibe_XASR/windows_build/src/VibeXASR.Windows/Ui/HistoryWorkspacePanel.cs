using System;
using System.Collections.Generic;
using System.Drawing;
using System.Linq;
using System.Windows.Forms;
using VibeXASR.Windows.Storage;
using H = VibeXASR.Windows.Storage.HistoryClustering;

namespace VibeXASR.Windows.Ui;

/// <summary>
/// The v1.4.0 记录 workspace (port of macOS HistoryWorkspace): search + aggregate + calendar
/// heatmap, day-grouped clustered rows, multi-select (click / shift-range), a batch toolbar
/// (merge / tag / delete / copy), undo, and double-click popup editing. Drives the
/// <see cref="HistoryStore"/> directly (single source of truth) and rebuilds from a snapshot
/// each mutation.
/// </summary>
internal sealed class HistoryWorkspacePanel : Panel
{
    private readonly HistoryStore _store;

    // filter / view state
    private string _query = "";
    private string? _selectedDay;
    private string? _tagFilter;
    private bool _aggregate = true;
    private bool _showCalendar;
    private readonly H.AggOptions _opts = new() { Mode = H.AggMode.Pause, GapSeconds = 120, TargetChars = 120 };

    // selection + undo
    private readonly HashSet<Guid> _selection = new();
    private readonly List<List<HistoryEntry>> _undo = new();
    private List<Guid> _flatIds = new();   // current display order (for shift-range)
    private int _lastClickIdx = -1;

    // controls
    private readonly TextBox _search;
    private readonly HistoryCalendarControl _calendar;
    private readonly Panel _selBar;
    private readonly Label _selLabel, _stats, _toast;
    private readonly FlowLayoutPanel _listHost;
    private readonly VibeButton _aggBtn, _calBtn, _undoBtn, _exportBtn, _clearBtn;
    private System.Windows.Forms.Timer? _toastTimer;

    public HistoryWorkspacePanel(HistoryStore store)
    {
        _store = store;
        BackColor = Theme.Surface;

        _search = new TextBox
        {
            Font = Theme.Ui(10f), BackColor = Theme.Surface2, ForeColor = Theme.Text,
            BorderStyle = BorderStyle.FixedSingle, PlaceholderText = Zh ? "搜索记录 / 标签…" : "Search records / tags…",
        };
        _search.TextChanged += (_, _) => { _query = _search.Text; Rebuild(); };

        _aggBtn = Tb(Zh ? "聚合" : "Group", () => { _aggregate = !_aggregate; Rebuild(); });
        _calBtn = Tb(Zh ? "日历" : "Calendar", () => { _showCalendar = !_showCalendar; Relayout(); Rebuild(); });
        _undoBtn = Tb(Zh ? "撤销" : "Undo", Undo);
        _exportBtn = Tb(Zh ? "导出" : "Export", ExportAll);
        _clearBtn = Tb(Zh ? "清空" : "Clear all", ClearAll);

        _calendar = new HistoryCalendarControl { Visible = false };
        _calendar.DaySelected += day => { _selectedDay = day; Rebuild(); };
        _calendar.MonthChanged += RefreshCalendarCounts;

        _selBar = new Panel { BackColor = Theme.AccentSoft, Visible = false };
        _selLabel = new Label { Font = Theme.Ui(9.5f, FontStyle.Bold), ForeColor = Theme.Text, AutoSize = true, BackColor = Color.Transparent, Location = new Point(12, 11) };
        _selBar.Controls.Add(_selLabel);
        int sx = 130;
        foreach (var (label, act) in new (string, Action)[]
                 {
                     (Zh ? "合并" : "Merge", () => MergeSelected(false)),
                     (Zh ? "整理成笔记" : "To note", () => MergeSelected(true)),
                     (Zh ? "加标签" : "Tag", TagSelected),
                     (Zh ? "复制" : "Copy", CopySelected),
                     (Zh ? "删除" : "Delete", DeleteSelected),
                     (Zh ? "取消" : "Cancel", () => { _selection.Clear(); Rebuild(); }),
                 })
        {
            var b = new VibeButton { Text = label, Style = VibeButton.Kind.Ghost, Size = new Size(Math.Max(56, TextRenderer.MeasureText(label, Theme.Ui(9f)).Width + 20), 26), Location = new Point(sx, 7) };
            b.Click += (_, _) => act();
            _selBar.Controls.Add(b); sx += b.Width + 6;
        }

        _stats = new Label { Font = Theme.Mono(8.5f), ForeColor = Theme.TextMuted, AutoSize = false, TextAlign = ContentAlignment.MiddleLeft, BackColor = Color.Transparent };
        _toast = new Label { Font = Theme.Ui(9.5f, FontStyle.Bold), ForeColor = Color.White, BackColor = Theme.AccentA, AutoSize = false, TextAlign = ContentAlignment.MiddleCenter, Visible = false };

        _listHost = new FlowLayoutPanel { FlowDirection = FlowDirection.TopDown, WrapContents = false, AutoScroll = true, BackColor = Theme.Surface, Padding = new Padding(0, 2, 0, 12) };

        Controls.Add(_search); Controls.Add(_aggBtn); Controls.Add(_calBtn); Controls.Add(_undoBtn);
        Controls.Add(_exportBtn); Controls.Add(_clearBtn);
        Controls.Add(_calendar); Controls.Add(_selBar); Controls.Add(_stats); Controls.Add(_listHost); Controls.Add(_toast);

        Rebuild();
    }

    private static bool Zh => L10n.Resolved == Lang.Zh;
    private VibeButton Tb(string text, Action act)
    {
        var b = new VibeButton { Text = text, Style = VibeButton.Kind.Ghost, Size = new Size(Math.Max(52, TextRenderer.MeasureText(text, Theme.Ui(9f)).Width + 20), 28) };
        b.Click += (_, _) => act();
        return b;
    }

    private int _lastW = -1;
    protected override void OnSizeChanged(EventArgs e)
    {
        base.OnSizeChanged(e);
        Relayout();
        if (ClientSize.Width != _lastW) { _lastW = ClientSize.Width; Rebuild(); }
    }

    private void Relayout()
    {
        int w = ClientSize.Width, pad = 12;
        int bx = w - pad;
        foreach (var b in new[] { _clearBtn, _exportBtn, _undoBtn, _calBtn, _aggBtn })
        {
            bx -= b.Width; b.Location = new Point(bx, 8); bx -= 6;
        }
        _search.SetBounds(pad, 9, Math.Max(120, bx - pad - 6), 26);

        int y = 44;
        if (_showCalendar)
        {
            _calendar.Visible = true;
            _calendar.SetBounds(pad, y, w - pad * 2, _calendar.Height);
            y += _calendar.Height + 6;
        }
        else _calendar.Visible = false;

        if (_selection.Count > 0)
        {
            _selBar.Visible = true; _selBar.SetBounds(0, y, w, 40); y += 40;
        }
        else _selBar.Visible = false;

        _stats.SetBounds(pad, y, w - pad * 2, 20); y += 22;
        _listHost.SetBounds(0, y, w, Math.Max(0, ClientSize.Height - y));
        _toast.SetBounds(w / 2 - 110, ClientSize.Height - 46, 220, 32);
    }

    // ----- rebuild -----

    private void Rebuild()
    {
        var entries = _store.List();
        var filters = new H.Filters
        {
            ShowOnCall = true, TagFilter = _tagFilter, Query = _query,
            SelectedDay = _selectedDay, Aggregate = _aggregate, Opts = _opts,
        };
        var groups = H.BuildGroups(entries, filters);

        _flatIds = new();
        _listHost.SuspendLayout();
        _listHost.Controls.Clear();
        int innerW = Math.Max(50, ClientSize.Width - 8 - SystemInformation.VerticalScrollBarWidth);

        if (groups.Count == 0)
            _listHost.Controls.Add(new Label { Text = Zh ? "没有记录" : "No records", Font = Theme.Ui(10f), ForeColor = Theme.TextMuted, AutoSize = false, Size = new Size(innerW, 60), TextAlign = ContentAlignment.MiddleCenter });

        foreach (var grp in groups)
        {
            _listHost.Controls.Add(DayHeader(grp, innerW));
            foreach (var node in grp.Nodes)
            {
                foreach (var it in node.Items) _flatIds.Add(it.Id);
                _listHost.Controls.Add(NodeRow(node, innerW));
            }
        }
        _listHost.ResumeLayout();

        _aggBtn.Text = (_aggregate ? "✓ " : "") + (Zh ? "聚合" : "Group");
        _calBtn.Text = (_showCalendar ? "✓ " : "") + (Zh ? "日历" : "Calendar");
        long life = _store.LifetimeChars;
        _stats.Text = (Zh ? $"累计 {life} 字 · 当前 {entries.Count} 条" : $"{life} chars total · {entries.Count} records")
                      + (_selectedDay is { } sd ? (Zh ? $" · 已筛选 {sd}" : $" · day {sd}") : "")
                      + (_tagFilter is { } tf ? $" · #{tf}" : "");
        _undoBtn.Enabled = _undo.Count > 0;
        UpdateSelBar();
        if (_showCalendar) RefreshCalendarCounts();
        Relayout();
    }

    private Control DayHeader(H.DayGroup grp, int w)
    {
        var p = new Panel { Size = new Size(w, 30), BackColor = Theme.Surface, Margin = new Padding(0) };
        var lbl = new Label
        {
            Text = grp.Date.LocalDateTime.ToString(Zh ? "M月d日 dddd" : "MMM d, ddd", System.Globalization.CultureInfo.GetCultureInfo(Zh ? "zh-CN" : "en-US")) + $"  ·  {grp.Count}",
            Font = Theme.Ui(9.5f, FontStyle.Bold), ForeColor = Theme.TextMuted, AutoSize = false,
            Location = new Point(14, 6), Size = new Size(w - 90, 20), BackColor = Color.Transparent,
        };
        var sel = new VibeButton { Text = Zh ? "选本天" : "Select day", Style = VibeButton.Kind.Ghost, Size = new Size(72, 22), Location = new Point(w - 84, 4) };
        var ids = grp.Nodes.SelectMany(n => n.Items.Select(i => i.Id)).ToList();
        sel.Click += (_, _) => { foreach (var id in ids) _selection.Add(id); Rebuild(); };
        p.Controls.Add(lbl); p.Controls.Add(sel);
        return p;
    }

    private Control NodeRow(H.HNode node, int w)
    {
        var ids = node.Items.Select(i => i.Id).ToList();
        bool selected = ids.All(id => _selection.Contains(id)) && ids.Count > 0;
        var first = node.Items[0];
        var newest = node.Items[^1];
        string text = node.Kind switch
        {
            H.HNodeKind.Single => first.Text,
            H.HNodeKind.OnCall => string.Join("  ", node.Items.Select(i => i.Text)),
            _ => string.Join("", node.Items.Select(i => i.Text)),
        };
        string preview = text.Replace("\n", " ");
        if (preview.Length > 140) preview = preview[..140] + "…";

        var tags = node.Items.SelectMany(i => i.Tags).Distinct().ToList();
        int textH = Math.Max(22, SettingsForm.MeasureWrapped(preview, Theme.Ui(10f), w - 64));
        int rowH = 14 + textH + (tags.Count > 0 ? 22 : 0) + 18;

        var row = new Panel { Size = new Size(w, rowH), BackColor = selected ? Theme.AccentSoft : Theme.Surface, Margin = new Padding(0, 0, 0, 1) };

        // checkbox dot
        var dot = new Label { Text = selected ? "☑" : "☐", Font = Theme.Ui(11f), ForeColor = selected ? Theme.AccentA : Theme.TextMuted, AutoSize = false, Size = new Size(24, rowH), Location = new Point(8, 0), TextAlign = ContentAlignment.TopCenter, BackColor = Color.Transparent, Padding = new Padding(0, 12, 0, 0) };
        row.Controls.Add(dot);

        // text
        row.Controls.Add(new Label { Text = preview, Font = Theme.Ui(10f), ForeColor = Theme.Text, AutoSize = false, Location = new Point(36, 12), Size = new Size(w - 44 - (node.Kind == H.HNodeKind.Cluster ? 64 : 0), textH), BackColor = Color.Transparent });

        // meta line: time · mode · (cluster/oncall badge)
        string badge = node.Kind switch
        {
            H.HNodeKind.Cluster => Zh ? $"📎 {node.Items.Count} 句" : $"📎 {node.Items.Count}",
            H.HNodeKind.OnCall => Zh ? $"📞 OnCall · {node.Items.Count}" : $"📞 OnCall · {node.Items.Count}",
            _ => ModeBadge(first.Mode),
        };
        string meta = $"{newest.Timestamp.LocalDateTime:HH:mm}　{badge}" + (first.Title is { Length: > 0 } t ? $"　「{t}」" : "");
        row.Controls.Add(new Label { Text = meta, Font = Theme.Mono(8f), ForeColor = Theme.TextMuted, AutoSize = false, Location = new Point(36, 12 + textH + (tags.Count > 0 ? 22 : 0)), Size = new Size(w - 100, 16), BackColor = Color.Transparent });

        // tags
        if (tags.Count > 0)
        {
            int tx = 36;
            foreach (var tag in tags.Take(6))
            {
                var chip = new Label { Text = "#" + tag, Font = Theme.Mono(8f), ForeColor = Theme.AccentA, BackColor = Theme.Surface2, AutoSize = false, Size = new Size(TextRenderer.MeasureText("#" + tag, Theme.Mono(8f)).Width + 12, 18), Location = new Point(tx, 12 + textH + 2), TextAlign = ContentAlignment.MiddleCenter };
                var captured = tag;
                chip.Click += (_, _) => { _tagFilter = _tagFilter == captured ? null : captured; Rebuild(); };
                chip.Cursor = Cursors.Hand;
                row.Controls.Add(chip); tx += chip.Width + 5;
            }
        }

        // cluster merge button
        if (node.Kind == H.HNodeKind.Cluster)
        {
            var mb = new VibeButton { Text = Zh ? "合并" : "Merge", Style = VibeButton.Kind.Solid, Size = new Size(56, 26), Location = new Point(w - 64, 10) };
            mb.Click += (_, _) => { PushUndo(); _store.Merge(ids, false, null); Toast(Zh ? $"已合并 {ids.Count} 句" : $"Merged {ids.Count}"); _selection.Clear(); Rebuild(); };
            row.Controls.Add(mb);
        }

        // interactions: click row (or dot) toggles selection; double-click single → edit
        void ToggleSelect(bool shift)
        {
            if (shift && _lastClickIdx >= 0 && ids.Count > 0)
            {
                int idx = _flatIds.IndexOf(ids[0]);
                if (idx >= 0)
                    for (int i = Math.Min(_lastClickIdx, idx); i <= Math.Max(_lastClickIdx, idx); i++)
                        if (i < _flatIds.Count) _selection.Add(_flatIds[i]);
            }
            else
            {
                bool all = ids.All(id => _selection.Contains(id));
                foreach (var id in ids) { if (all) _selection.Remove(id); else _selection.Add(id); }
                if (ids.Count > 0) _lastClickIdx = _flatIds.IndexOf(ids[0]);
            }
            Rebuild();
        }
        foreach (var c in new Control[] { row, dot })
        {
            c.Cursor = Cursors.Hand;
            c.MouseDown += (_, ev) => { if (ev.Button == MouseButtons.Left) ToggleSelect((Control.ModifierKeys & Keys.Shift) != 0); };
            if (node.Kind == H.HNodeKind.Single)
                c.DoubleClick += (_, _) => EditEntry(first);
        }
        return row;
    }

    private static string ModeBadge(string mode) => mode switch
    {
        "type" => "Type", "oncall" => "OnCall", "manual" => "笔记", _ => "Paste",
    };

    // ----- mutations -----

    private void PushUndo() { _undo.Add(_store.Snapshot()); if (_undo.Count > 12) _undo.RemoveAt(0); }
    private void Undo() { if (_undo.Count == 0) return; var snap = _undo[^1]; _undo.RemoveAt(_undo.Count - 1); _store.Restore(snap); _selection.Clear(); Toast(Zh ? "已撤销" : "Undone"); Rebuild(); }

    private void MergeSelected(bool asNote)
    {
        var ids = _selection.ToList();
        if (ids.Count < (asNote ? 1 : 2)) return;
        PushUndo();
        _store.Merge(ids, asNote, asNote ? (Zh ? "整理笔记" : "Note") : null);
        Toast(asNote ? (Zh ? "已整理为笔记" : "Saved as note") : (Zh ? $"已合并 {ids.Count} 条" : $"Merged {ids.Count}"));
        _selection.Clear(); Rebuild();
    }

    private void TagSelected()
    {
        var ids = _selection.ToList(); if (ids.Count == 0) return;
        var tag = Prompt(Zh ? "标签名:" : "Tag:");
        if (string.IsNullOrWhiteSpace(tag)) return;
        PushUndo(); _store.ApplyTag(ids, tag.Trim());
        Toast(Zh ? $"已为 {ids.Count} 条加标签" : $"Tagged {ids.Count}"); _selection.Clear(); Rebuild();
    }

    private void DeleteSelected()
    {
        var ids = _selection.ToList(); if (ids.Count == 0) return;
        if (MessageBox.Show(this, Zh ? $"删除选中的 {ids.Count} 条?" : $"Delete {ids.Count} records?", "Vibe XASR", MessageBoxButtons.OKCancel) != DialogResult.OK) return;
        PushUndo(); foreach (var id in ids) _store.Delete(id);
        Toast(Zh ? $"已删除 {ids.Count} 条" : $"Deleted {ids.Count}"); _selection.Clear(); Rebuild();
    }

    private void CopySelected()
    {
        var ids = new HashSet<Guid>(_selection);
        var txt = string.Join("\n", _store.List().Where(e => ids.Contains(e.Id)).OrderBy(e => e.Timestamp).Select(e => e.Text));
        if (txt.Length > 0) { try { Clipboard.SetText(txt); } catch { } Toast(Zh ? $"已复制 {ids.Count} 条" : $"Copied {ids.Count}"); }
    }

    private void ClearAll()
    {
        if (MessageBox.Show(this, Zh ? "清空全部记录?(可撤销)" : "Clear all records?", "Vibe XASR", MessageBoxButtons.OKCancel) != DialogResult.OK) return;
        PushUndo(); _store.ClearAll(); Toast(Zh ? "已清空" : "Cleared"); _selection.Clear(); Rebuild();
    }

    private void ExportAll()
    {
        using var dlg = new SaveFileDialog { FileName = "vibe-records.txt", Filter = "Text|*.txt|JSON|*.json" };
        if (dlg.ShowDialog(this) != DialogResult.OK) return;
        var asc = _store.List().OrderBy(e => e.Timestamp).ToList();
        try
        {
            if (dlg.FilterIndex == 2)
            {
                var arr = asc.Select(e => new Dictionary<string, object> { ["date"] = e.Timestamp.ToString("o"), ["text"] = e.Text, ["mode"] = e.Mode, ["tags"] = e.Tags });
                System.IO.File.WriteAllText(dlg.FileName, System.Text.Json.JsonSerializer.Serialize(arr, new System.Text.Json.JsonSerializerOptions { WriteIndented = true, Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping }));
            }
            else System.IO.File.WriteAllText(dlg.FileName, string.Join("\n\n", asc.Select(e => $"{e.Timestamp.LocalDateTime:g}\n{e.Text}")));
            Toast(Zh ? $"已导出 {asc.Count} 条" : $"Exported {asc.Count}");
        }
        catch { Toast(Zh ? "导出失败" : "Export failed"); }
    }

    private void EditEntry(HistoryEntry e)
    {
        using var f = new HistoryEditPopup(e, Zh);
        if (f.ShowDialog(this) != DialogResult.OK) return;
        PushUndo();
        if (string.IsNullOrWhiteSpace(f.ResultText)) _store.Delete(e.Id);
        else _store.Update(e.Id, f.ResultText, f.ResultTitle, f.ResultTags);
        Rebuild();
    }

    // ----- helpers -----

    private void UpdateSelBar()
    {
        _selLabel.Text = Zh ? $"已选 {_selection.Count} 条" : $"{_selection.Count} selected";
    }

    private void RefreshCalendarCounts()
    {
        var counts = new Dictionary<string, int>();
        foreach (var e in _store.List())
        {
            var k = H.DayKey(e.Timestamp);
            counts[k] = counts.TryGetValue(k, out var c) ? c + 1 : 1;
        }
        _calendar.SetData(_calendar.MonthCursor, counts, _selectedDay);
    }

    private void Toast(string msg)
    {
        _toast.Text = msg; _toast.Visible = true; _toast.BringToFront();
        _toastTimer?.Stop(); _toastTimer?.Dispose();
        _toastTimer = new System.Windows.Forms.Timer { Interval = 2200 };
        _toastTimer.Tick += (_, _) => { _toastTimer!.Stop(); _toastTimer.Dispose(); _toastTimer = null; if (!_toast.IsDisposed) _toast.Visible = false; };
        _toastTimer.Start();
    }

    private string? Prompt(string label)
    {
        using var f = new Form { Text = "Vibe XASR", ClientSize = new Size(320, 110), FormBorderStyle = FormBorderStyle.FixedDialog, StartPosition = FormStartPosition.CenterParent, MaximizeBox = false, MinimizeBox = false, BackColor = Theme.Surface };
        var lbl = new Label { Text = label, ForeColor = Theme.Text, AutoSize = true, Location = new Point(14, 14), Font = Theme.Ui(10f), BackColor = Color.Transparent };
        var tb = new TextBox { Location = new Point(14, 38), Size = new Size(292, 24), BackColor = Theme.Surface2, ForeColor = Theme.Text, BorderStyle = BorderStyle.FixedSingle, Font = Theme.Ui(10f) };
        var ok = new VibeButton { Text = "OK", Style = VibeButton.Kind.Solid, Size = new Size(70, 28), Location = new Point(236, 70) };
        ok.Click += (_, _) => { f.DialogResult = DialogResult.OK; };
        f.Controls.Add(lbl); f.Controls.Add(tb); f.Controls.Add(ok);
        return f.ShowDialog(this) == DialogResult.OK ? tb.Text : null;
    }
}

/// <summary>Modal editor for one record: text + optional note title + comma-separated tags.</summary>
internal sealed class HistoryEditPopup : Form
{
    private readonly TextBox _text, _title, _tags;
    public string ResultText => _text.Text;
    public string? ResultTitle => string.IsNullOrWhiteSpace(_title.Text) ? null : _title.Text.Trim();
    public List<string> ResultTags => _tags.Text.Split(new[] { ',', '，' }, StringSplitOptions.RemoveEmptyEntries).Select(s => s.Trim()).Where(s => s.Length > 0).Distinct().ToList();

    public HistoryEditPopup(HistoryEntry e, bool zh)
    {
        Text = zh ? "编辑记录" : "Edit record";
        ClientSize = new Size(440, 320);
        FormBorderStyle = FormBorderStyle.FixedDialog; StartPosition = FormStartPosition.CenterParent;
        MaximizeBox = false; MinimizeBox = false; BackColor = Theme.Surface;

        Controls.Add(Lbl(zh ? "文字" : "Text", 12));
        _text = Edit(e.Text.Replace("\r\n", "\n").Replace("\n", "\r\n"), 32, 150, true);
        Controls.Add(_text);
        Controls.Add(Lbl(zh ? "笔记标题(可选)" : "Note title (optional)", 192));
        _title = Edit(e.Title ?? "", 212, 24, false); Controls.Add(_title);
        Controls.Add(Lbl(zh ? "标签(逗号分隔)" : "Tags (comma-separated)", 244));
        _tags = Edit(string.Join(", ", e.Tags), 264, 24, false); Controls.Add(_tags);

        var ok = new VibeButton { Text = zh ? "保存" : "Save", Style = VibeButton.Kind.Solid, Size = new Size(80, 30), Location = new Point(348, 282) };
        ok.Click += (_, _) => DialogResult = DialogResult.OK;
        var cancel = new VibeButton { Text = zh ? "取消" : "Cancel", Style = VibeButton.Kind.Ghost, Size = new Size(80, 30), Location = new Point(260, 282) };
        cancel.Click += (_, _) => DialogResult = DialogResult.Cancel;
        Controls.Add(ok); Controls.Add(cancel);
    }

    private static Label Lbl(string t, int y) => new() { Text = t, ForeColor = Theme.TextMuted, Font = Theme.Ui(9f), AutoSize = true, Location = new Point(14, y), BackColor = Color.Transparent };
    private static TextBox Edit(string text, int y, int h, bool multiline) => new()
    {
        Text = text, Multiline = multiline, ScrollBars = multiline ? ScrollBars.Vertical : ScrollBars.None,
        Location = new Point(14, y), Size = new Size(412, h), BackColor = Theme.Surface2, ForeColor = Theme.Text,
        BorderStyle = BorderStyle.FixedSingle, Font = multiline ? Theme.Mono(10f) : Theme.Ui(10f),
    };
}
