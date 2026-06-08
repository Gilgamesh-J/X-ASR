using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Threading;
using VibeXASR.Windows.Storage;
using H = VibeXASR.Windows.Storage.HistoryClustering;
using Brush = System.Windows.Media.Brush;
using Brushes = System.Windows.Media.Brushes;
using Color = System.Windows.Media.Color;
using FontFamily = System.Windows.Media.FontFamily;
using Button = System.Windows.Controls.Button;
using TextBox = System.Windows.Controls.TextBox;
using Orientation = System.Windows.Controls.Orientation;
using HorizontalAlignment = System.Windows.HorizontalAlignment;
using VerticalAlignment = System.Windows.VerticalAlignment;
using Cursors = System.Windows.Input.Cursors;
using MessageBox = System.Windows.MessageBox;
using Clipboard = System.Windows.Clipboard;
using Path = System.IO.Path;

namespace VibeXASR.Windows.Ui.Wpf;

/// <summary>The 记录 workspace (WPF). Full port of the WinForms HistoryWorkspacePanel: search +
/// aggregate (碎句聚合) + calendar heatmap, day-grouped clustered rows, multi-select (click /
/// Shift-range), a batch toolbar (merge / to-note / tag / copy / delete), undo, and double-click
/// edit. Drives <see cref="HistoryStore"/> directly via the UI-agnostic <see cref="H"/> clustering.</summary>
public partial class HistoryWindow : Window
{
    private readonly HistoryStore _store;
    private readonly DispatcherTimer _tick = new() { Interval = TimeSpan.FromSeconds(1) };
    private static bool Zh => L10n.Resolved is Lang.Zh or Lang.Hant;

    // filter / view state
    private string _query = "";
    private string? _selectedDay, _tagFilter;
    private bool _aggregate = true, _showCalendar;
    private H.AggMode _aggMode = H.AggMode.Pause;
    private int _gapMin = 2, _targetChars = 120;
    private H.AggOptions Opts => new() { Mode = _aggMode, GapSeconds = _gapMin * 60, TargetChars = _targetChars };
    private DateTime _monthCursor = DateTime.Today;

    // selection + undo
    private readonly HashSet<Guid> _selection = new();
    private readonly List<List<HistoryEntry>> _undo = new();
    private List<Guid> _flatIds = new();
    private int _lastClickIdx = -1;
    private bool _suppressUp;

    private Button? _aggBtn, _calBtn, _undoBtn;
    private DispatcherTimer? _toastTimer;

    public HistoryWindow(HistoryStore store)
    {
        _store = store;
        InitializeComponent();
        SourceInitialized += (_, _) => DarkTitleBar();

        SearchBox.TextChanged += (_, _) => { _query = SearchBox.Text; SearchPlaceholder.Visibility = string.IsNullOrEmpty(_query) ? Visibility.Visible : Visibility.Collapsed; Rebuild(); };
        SearchPlaceholder.Text = L10n.Loc("搜索记录 / 标签…", "Search records / tags…", "記録 / タグを検索…", "기록 / 태그 검색…");

        _aggBtn = ToolBtn(() => { _aggregate = !_aggregate; Rebuild(); });
        _calBtn = ToolBtn(() => { _showCalendar = !_showCalendar; Rebuild(); });
        _undoBtn = ToolBtn(Undo);
        ToolBtns.Children.Add(_aggBtn); ToolBtns.Children.Add(_calBtn); ToolBtns.Children.Add(_undoBtn);

        ExportBtn.Content = L10n.Loc("导出", "Export", "エクスポート", "내보내기");
        ClearBtn.Content = L10n.Loc("清空", "Clear all", "すべて消去", "전체 지우기"); ClearBtn.Foreground = Br("Danger");
        ExportBtn.Click += (_, _) => ExportAll();
        ClearBtn.Click += (_, _) => ClearAll();

        Rebuild();
        _tick.Tick += (_, _) => RefreshExpiry();
        _tick.Start();
        Closed += (_, _) => _tick.Stop();
        Loaded += (_, _) => SelfCapture();
    }

    private Button ToolBtn(Action act)
    {
        var b = new Button { Style = St("Ghost"), Height = 26, MinWidth = 0, Padding = new Thickness(10, 0, 10, 0), Margin = new Thickness(4, 0, 0, 0), FontSize = 12 };
        b.Click += (_, _) => act();
        return b;
    }

    // ===================== rebuild =====================

    private void Rebuild()
    {
        var entries = _store.List();
        var filters = new H.Filters { ShowOnCall = true, TagFilter = _tagFilter, Query = _query, SelectedDay = _selectedDay, Aggregate = _aggregate, Opts = Opts };
        var groups = H.BuildGroups(entries, filters);

        TitleText.Text = L10n.T("history.title");
        CountText.Text = L10n.T("history.count", entries.Count);
        ExportBtn.Visibility = ClearBtn.Visibility = entries.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
        if (_aggBtn is not null) _aggBtn.Content = (_aggregate ? "✓ " : "") + L10n.Loc("聚合", "Group", "グループ化", "그룹화");
        if (_calBtn is not null) _calBtn.Content = (_showCalendar ? "✓ " : "") + L10n.Loc("日历", "Calendar", "カレンダー", "달력");
        if (_undoBtn is not null) { _undoBtn.Content = L10n.Loc("撤销", "Undo", "元に戻す", "실행 취소"); _undoBtn.IsEnabled = _undo.Count > 0; _undoBtn.Opacity = _undo.Count > 0 ? 1 : 0.45; }

        AggHost.Content = _aggregate ? AggBar() : null;
        CalHost.Content = _showCalendar ? CalendarView() : null;
        SelHost.Content = _selection.Count > 0 ? SelBar() : null;

        long life = _store.LifetimeChars;
        StatsText.Text = L10n.Loc($"累计 {life:N0} 字 · 当前 {entries.Count} 条", $"{life:N0} chars · {entries.Count} records", $"累計 {life:N0} 文字 · 現在 {entries.Count} 件", $"누적 {life:N0}자 · 현재 {entries.Count}건")
            + (_selectedDay is { } sd ? L10n.Loc($" · 已筛选 {sd}", $" · day {sd}", $" · 絞り込み {sd}", $" · 필터 {sd}") : "")
            + (_tagFilter is { } tf ? $" · #{tf}" : "");

        _flatIds = new();
        List.Children.Clear();
        if (groups.Count == 0)
        {
            List.Children.Add(new TextBlock { Text = "🗒\n\n" + L10n.Loc("没有记录", "No records", "記録なし", "기록 없음"), Foreground = Br("TextMuted"), FontSize = 13, TextAlignment = TextAlignment.Center, HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 70, 0, 0) });
            return;
        }
        foreach (var grp in groups)
        {
            List.Children.Add(DayHeader(grp));
            foreach (var node in grp.Nodes)
            {
                foreach (var it in node.Items) _flatIds.Add(it.Id);
                List.Children.Add(NodeRow(node));
            }
        }
    }

    private FrameworkElement DayHeader(H.DayGroup grp)
    {
        var g = new Grid { Margin = new Thickness(2, 10, 2, 4) };
        g.ColumnDefinitions.Add(new ColumnDefinition());
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var lbl = new TextBlock
        {
            Text = grp.Date.LocalDateTime.ToString(Zh ? "M月d日 dddd" : "MMM d, ddd", CultureInfo.GetCultureInfo(Zh ? "zh-CN" : "en-US")) + $"  ·  {grp.Count}",
            Foreground = Br("TextMuted"), FontSize = 12, FontWeight = FontWeights.SemiBold, VerticalAlignment = VerticalAlignment.Center,
        };
        g.Children.Add(lbl);
        var ids = grp.Nodes.SelectMany(n => n.Items.Select(i => i.Id)).ToList();
        var sel = new TextBlock { Text = L10n.Loc("选本天", "Select day", "この日を選択", "이 날 선택"), Foreground = Br("AccentA"), FontSize = 11.5, Cursor = Cursors.Hand, VerticalAlignment = VerticalAlignment.Center };
        sel.MouseLeftButtonUp += (_, _) => { foreach (var id in ids) _selection.Add(id); Rebuild(); };
        Grid.SetColumn(sel, 1); g.Children.Add(sel);
        return g;
    }

    private FrameworkElement NodeRow(H.HNode node)
    {
        var ids = node.Items.Select(i => i.Id).ToList();
        bool selected = ids.Count > 0 && ids.All(id => _selection.Contains(id));
        var first = node.Items[0];
        var newest = node.Items[^1];
        string text = node.Kind switch
        {
            H.HNodeKind.Single => first.Text,
            H.HNodeKind.OnCall => string.Join("  ", node.Items.Select(i => i.Text)),
            _ => string.Join("", node.Items.Select(i => i.Text)),
        };
        string preview = text.Replace("\n", " ");
        if (preview.Length > 200) preview = preview[..200] + "…";
        var tags = node.Items.SelectMany(i => i.Tags).Distinct().ToList();

        var grid = new Grid { Margin = new Thickness(12, 10, 12, 10) };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });   // dot
        grid.ColumnDefinitions.Add(new ColumnDefinition());                              // body
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });   // merge btn

        var dot = new TextBlock { Text = selected ? "☑" : "☐", Foreground = selected ? Br("AccentA") : Br("TextMuted"), FontSize = 15, VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(0, 1, 10, 0) };
        Grid.SetColumn(dot, 0); grid.Children.Add(dot);

        var body = new StackPanel();
        body.Children.Add(new TextBlock { Text = preview, Foreground = Br("Text"), FontSize = 13, TextWrapping = TextWrapping.Wrap, LineHeight = 19 });
        if (tags.Count > 0)
        {
            var chips = new WrapPanel { Margin = new Thickness(0, 6, 0, 0) };
            foreach (var tag in tags.Take(8))
            {
                var captured = tag;
                var chip = new Border { CornerRadius = new CornerRadius(5), Background = Br("Surface2"), Padding = new Thickness(7, 2, 7, 2), Margin = new Thickness(0, 0, 5, 4), Cursor = Cursors.Hand, Child = new TextBlock { Text = "#" + tag, Foreground = _tagFilter == tag ? Br("AccentB") : Br("AccentA"), FontFamily = new FontFamily("Cascadia Mono, Consolas"), FontSize = 10.5 } };
                chip.MouseLeftButtonUp += (_, e) => { e.Handled = true; _tagFilter = _tagFilter == captured ? null : captured; Rebuild(); };
                chips.Children.Add(chip);
            }
            body.Children.Add(chips);
        }
        string badge = node.Kind switch
        {
            H.HNodeKind.Cluster => L10n.Loc($"📎 {node.Items.Count} 句", $"📎 {node.Items.Count}", $"📎 {node.Items.Count} 文", $"📎 {node.Items.Count} 문장"),
            H.HNodeKind.OnCall => $"📞 OnCall · {node.Items.Count}",
            _ => ModeBadge(first.Mode),
        };
        string meta = $"{newest.Timestamp.LocalDateTime:HH:mm}　{badge}" + (first.Title is { Length: > 0 } t ? $"　「{t}」" : "");
        if (node.Items.Any(i => i.ExpiresAt is not null))
        {
            var exp = node.Items.Select(i => i.ExpiresAt).Where(x => x is not null).Min();
            if (exp is { } e2) meta += $"　⏳ {Math.Max(0, (int)Math.Ceiling((e2 - DateTimeOffset.Now).TotalSeconds))}s";
        }
        body.Children.Add(new TextBlock { Text = meta, Foreground = Br("TextMuted"), FontFamily = new FontFamily("Cascadia Mono, Consolas"), FontSize = 10.5, Margin = new Thickness(0, 6, 0, 0) });
        Grid.SetColumn(body, 1); grid.Children.Add(body);

        // hover action bar (build 205 parity): per-row 合并上/下条 + 标签/复制/编辑/删除 icons
        var actions = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Top, Visibility = Visibility.Collapsed };
        if (node.Kind == H.HNodeKind.Cluster)
            actions.Children.Add(IconAct("📎", false, L10n.Loc("合并整簇", "Merge cluster", "クラスタを結合", "클러스터 병합"), () => { PushUndo(); _store.Merge(ids, false, null); ShowToast(L10n.Loc($"已合并 {ids.Count} 句", $"Merged {ids.Count}", $"{ids.Count}件を結合", $"{ids.Count}개 병합")); _selection.Clear(); Rebuild(); }));
        if (node.Kind == H.HNodeKind.Single)
        {
            int fi = _flatIds.IndexOf(first.Id);
            if (fi > 0) actions.Children.Add(IconAct("⬆", false, L10n.Loc("合并上一条", "Merge up", "上の項目と結合", "위 항목과 병합"), () => MergeAdjacent(first.Id, -1)));
            if (fi >= 0 && fi < _flatIds.Count - 1) actions.Children.Add(IconAct("⬇", false, L10n.Loc("合并下一条", "Merge down", "下の項目と結合", "아래 항목과 병합"), () => MergeAdjacent(first.Id, +1)));
            actions.Children.Add(IconAct("✎", false, L10n.Loc("编辑", "Edit", "編集", "편집"), () => EditEntry(first)));
        }
        actions.Children.Add(IconAct("🏷", false, L10n.Loc("加标签", "Tag", "タグを付ける", "태그 추가"), () => TagIds(ids)));
        actions.Children.Add(IconAct("⧉", false, L10n.Loc("复制", "Copy", "コピー", "복사"), () => { try { Clipboard.SetText(text); } catch { } ShowToast(L10n.Loc("已复制", "Copied", "コピーしました", "복사됨")); }));
        actions.Children.Add(IconAct("🗑", true, L10n.Loc("删除", "Delete", "削除", "삭제"), () => { PushUndo(); foreach (var id in ids) _store.Delete(id); ShowToast(L10n.Loc("已删除", "Deleted", "削除しました", "삭제됨")); _selection.Remove(first.Id); Rebuild(); }));
        Grid.SetColumn(actions, 2); grid.Children.Add(actions);

        var card = new Border { Style = St("Card"), Margin = new Thickness(0, 0, 0, 7), Cursor = Cursors.Hand, Child = grid };
        if (selected) { card.Background = Br("AccentSoft"); card.BorderBrush = Br("AccentA"); card.BorderThickness = new Thickness(1.2); }
        card.MouseEnter += (_, _) => actions.Visibility = Visibility.Visible;
        card.MouseLeave += (_, _) => actions.Visibility = Visibility.Collapsed;

        void Toggle(bool shift)
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
        card.PreviewMouseLeftButtonDown += (_, e) =>
        {
            if (e.ClickCount == 2 && node.Kind == H.HNodeKind.Single) { _suppressUp = true; e.Handled = true; EditEntry(first); }
        };
        card.MouseLeftButtonUp += (_, e) =>
        {
            if (_suppressUp) { _suppressUp = false; return; }
            if (e.OriginalSource is FrameworkElement fe && fe.Cursor == Cursors.Hand && fe is Border bb && bb != card) return; // a chip/button handled it
            Toggle((Keyboard.Modifiers & ModifierKeys.Shift) != 0);
        };
        return card;
    }

    private static string ModeBadge(string mode) => mode switch { "type" => "Type", "oncall" => "OnCall", "manual" => "笔记", _ => "Paste" };

    private Border IconAct(string glyph, bool danger, string tip, Action onClick)
    {
        var b = new Border { CornerRadius = new CornerRadius(6), Background = System.Windows.Media.Brushes.Transparent, Padding = new Thickness(5, 3, 5, 3), Margin = new Thickness(2, 0, 0, 0), Cursor = Cursors.Hand, ToolTip = tip,
            Child = new TextBlock { Text = glyph, FontSize = 13, Foreground = danger ? Br("Danger") : Br("TextMuted") } };
        b.MouseEnter += (_, _) => b.Background = Br("Surface2");
        b.MouseLeave += (_, _) => b.Background = System.Windows.Media.Brushes.Transparent;
        b.MouseLeftButtonUp += (_, e) => { e.Handled = true; onClick(); };
        return b;
    }

    /// <summary>Merge a single record with its neighbour in display order (dir = -1 上一条 / +1 下一条).</summary>
    private void MergeAdjacent(Guid id, int dir)
    {
        int i = _flatIds.IndexOf(id), j = i + dir;
        if (i < 0 || j < 0 || j >= _flatIds.Count) return;
        PushUndo();
        // merge in timestamp order so the combined text reads chronologically
        var pair = new[] { _flatIds[Math.Min(i, j)], _flatIds[Math.Max(i, j)] };
        _store.Merge(pair, false, null);
        ShowToast(L10n.Loc("已合并", "Merged", "結合しました", "병합됨")); _selection.Clear(); Rebuild();
    }

    private void TagIds(List<Guid> ids)
    {
        if (ids.Count == 0) return;
        var tag = Prompt(L10n.Loc("标签名:", "Tag:", "タグ名:", "태그 이름:"));
        if (string.IsNullOrWhiteSpace(tag)) return;
        PushUndo(); _store.ApplyTag(ids, tag.Trim());
        ShowToast(L10n.Loc("已加标签", "Tagged", "タグを付けました", "태그 추가됨")); Rebuild();
    }

    // ===================== aggregate options bar =====================

    private FrameworkElement AggBar()
    {
        var bar = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
        bar.Children.Add(new TextBlock { Text = L10n.Loc("聚合方式", "Group by", "グループ化方法", "그룹화 방식"), Foreground = Br("TextMuted"), FontSize = 11.5, FontWeight = FontWeights.SemiBold, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(2, 0, 10, 0) });
        bar.Children.Add(Seg(new[] { ("pause", L10n.Loc("按停顿", "By pause", "間隔で", "휴지로")), ("chars", L10n.Loc("按字数", "By chars", "文字数で", "글자수로")) }, _aggMode == H.AggMode.Pause ? "pause" : "chars",
            v => { var m = v == "chars" ? H.AggMode.Chars : H.AggMode.Pause; if (m != _aggMode) { _aggMode = m; Rebuild(); } }));
        var spacer = new Border { Width = 10 }; bar.Children.Add(spacer);
        if (_aggMode == H.AggMode.Pause)
            bar.Children.Add(Seg(new[] { 1, 2, 5, 10 }.Select(n => (n.ToString(), L10n.Loc($"≤{n}分", $"≤{n}m", $"≤{n}分", $"≤{n}분"))).ToArray(), _gapMin.ToString(),
                v => { if (int.TryParse(v, out var n) && n != _gapMin) { _gapMin = n; Rebuild(); } }));
        else
            bar.Children.Add(Seg(new[] { 60, 120, 200, 300 }.Select(n => (n.ToString(), L10n.Loc($"{n}字", $"{n}c", $"{n}文字", $"{n}자"))).ToArray(), _targetChars.ToString(),
                v => { if (int.TryParse(v, out var n) && n != _targetChars) { _targetChars = n; Rebuild(); } }));
        return new Border { Background = Br("Surface2"), CornerRadius = new CornerRadius(9), Padding = new Thickness(12, 6, 12, 6), Margin = new Thickness(0, 6, 0, 0), Child = bar };
    }

    private FrameworkElement Seg((string val, string label)[] opts, string value, Action<string> onPick)
    {
        var outer = new Border { CornerRadius = new CornerRadius(7), Background = Br("Surface"), Padding = new Thickness(2) };
        var sp = new StackPanel { Orientation = Orientation.Horizontal };
        foreach (var (v, l) in opts)
        {
            bool sel = v == value;
            var seg = new Border { CornerRadius = new CornerRadius(5), Background = sel ? Br("AccentSoft") : Brushes.Transparent, Padding = new Thickness(12, 4, 12, 4), Cursor = Cursors.Hand, Child = new TextBlock { Text = l, Foreground = sel ? Br("AccentA") : Br("TextMuted"), FontSize = 11.5, FontWeight = sel ? FontWeights.SemiBold : FontWeights.Normal } };
            seg.MouseLeftButtonUp += (_, _) => onPick(v);
            sp.Children.Add(seg);
        }
        outer.Child = sp;
        return outer;
    }

    // ===================== calendar heatmap =====================

    private FrameworkElement CalendarView()
    {
        var counts = new Dictionary<string, int>();
        foreach (var e in _store.List()) { var k = H.DayKey(e.Timestamp); counts[k] = counts.TryGetValue(k, out var c) ? c + 1 : 1; }
        int max = counts.Count > 0 ? counts.Values.Max() : 1;

        var root = new StackPanel();
        // header: ‹ Month YYYY ›
        var hdr = new Grid { Margin = new Thickness(0, 0, 0, 6) };
        hdr.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        hdr.ColumnDefinitions.Add(new ColumnDefinition());
        hdr.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var prev = new TextBlock { Text = "‹", Foreground = Br("AccentA"), FontSize = 16, Cursor = Cursors.Hand, VerticalAlignment = VerticalAlignment.Center };
        prev.MouseLeftButtonUp += (_, _) => { _monthCursor = _monthCursor.AddMonths(-1); Rebuild(); };
        Grid.SetColumn(prev, 0); hdr.Children.Add(prev);
        hdr.Children.Add(new TextBlock { Text = _monthCursor.ToString(Zh ? "yyyy年M月" : "MMMM yyyy", CultureInfo.GetCultureInfo(Zh ? "zh-CN" : "en-US")), Foreground = Br("Text"), FontSize = 12.5, FontWeight = FontWeights.SemiBold, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center });
        var next = new TextBlock { Text = "›", Foreground = Br("AccentA"), FontSize = 16, Cursor = Cursors.Hand, VerticalAlignment = VerticalAlignment.Center };
        next.MouseLeftButtonUp += (_, _) => { _monthCursor = _monthCursor.AddMonths(1); Rebuild(); };
        Grid.SetColumn(next, 2); hdr.Children.Add(next);
        root.Children.Add(hdr);

        // weekday labels + 6x7 grid
        var days = H.MonthGrid(_monthCursor);   // 42 DateTimes
        var uni = new UniformGrid { Columns = 7, Rows = 7 };
        string[] wk = Zh ? new[] { "一", "二", "三", "四", "五", "六", "日" } : (L10n.Resolved == Lang.Ja ? new[] { "月", "火", "水", "木", "金", "土", "日" } : L10n.Resolved == Lang.Ko ? new[] { "월", "화", "수", "목", "금", "토", "일" } : new[] { "M", "T", "W", "T", "F", "S", "S" });
        foreach (var w in wk) uni.Children.Add(new TextBlock { Text = w, Foreground = Br("TextMuted"), FontSize = 10, HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 0, 0, 2) });
        foreach (var d in days)
        {
            string key = H.DayKey(new DateTimeOffset(d));
            int n = counts.TryGetValue(key, out var c) ? c : 0;
            bool thisMonth = d.Month == _monthCursor.Month;
            bool isSel = _selectedDay == key;
            var cell = new Border { CornerRadius = new CornerRadius(5), Margin = new Thickness(2), Height = 26, Background = HeatBrush(H.HeatLevel(n, max)), Cursor = Cursors.Hand, BorderBrush = isSel ? Br("AccentB") : Brushes.Transparent, BorderThickness = new Thickness(isSel ? 1.6 : 0), Opacity = thisMonth ? 1 : 0.35,
                Child = new TextBlock { Text = d.Day.ToString(), Foreground = n > 0 ? Brushes.White : Br("TextMuted"), FontSize = 10.5, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center } };
            var capKey = key;
            cell.MouseLeftButtonUp += (_, _) => { _selectedDay = _selectedDay == capKey ? null : capKey; Rebuild(); };
            uni.Children.Add(cell);
        }
        root.Children.Add(uni);
        return new Border { Background = Br("Surface2"), CornerRadius = new CornerRadius(10), Padding = new Thickness(12, 10, 12, 10), Child = root };
    }

    private Brush HeatBrush(int level) => level switch
    {
        0 => Br("Surface"),
        1 => new SolidColorBrush(Color.FromArgb(70, 0x7C, 0x5C, 0xFF)),
        2 => new SolidColorBrush(Color.FromArgb(130, 0x7C, 0x5C, 0xFF)),
        3 => new SolidColorBrush(Color.FromArgb(190, 0x7C, 0x5C, 0xFF)),
        _ => new SolidColorBrush(Color.FromArgb(240, 0x7C, 0x5C, 0xFF)),
    };

    // ===================== selection batch bar =====================

    private FrameworkElement SelBar()
    {
        var sp = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
        sp.Children.Add(new TextBlock { Text = L10n.Loc($"已选 {_selection.Count} 条", $"{_selection.Count} selected", $"{_selection.Count}件選択", $"{_selection.Count}개 선택"), Foreground = Br("Text"), FontSize = 12, FontWeight = FontWeights.SemiBold, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(2, 0, 14, 0) });
        void Add(string label, bool danger, Action act)
        {
            var b = new Button { Style = St("Ghost"), Content = label, Height = 26, Padding = new Thickness(10, 0, 10, 0), Margin = new Thickness(0, 0, 6, 0), FontSize = 12 };
            if (danger) b.Foreground = Br("Danger");
            b.Click += (_, _) => act();
            sp.Children.Add(b);
        }
        Add(L10n.Loc("合并", "Merge", "結合", "병합"), false, () => MergeSelected(false));
        Add(L10n.Loc("整理成笔记", "To note", "ノートにまとめる", "노트로 정리"), false, () => MergeSelected(true));
        Add(L10n.Loc("加标签", "Tag", "タグを付ける", "태그 추가"), false, TagSelected);
        Add(L10n.Loc("复制", "Copy", "コピー", "복사"), false, CopySelected);
        Add(L10n.Loc("删除", "Delete", "削除", "삭제"), true, DeleteSelected);
        Add(L10n.Loc("取消", "Cancel", "キャンセル", "취소"), false, () => { _selection.Clear(); Rebuild(); });
        return new Border { Background = Br("AccentSoft"), CornerRadius = new CornerRadius(9), Padding = new Thickness(12, 6, 12, 6), Child = sp };
    }

    // ===================== mutations =====================

    private void PushUndo() { _undo.Add(_store.Snapshot()); if (_undo.Count > 12) _undo.RemoveAt(0); }
    private void Undo() { if (_undo.Count == 0) return; var snap = _undo[^1]; _undo.RemoveAt(_undo.Count - 1); _store.Restore(snap); _selection.Clear(); ShowToast(L10n.Loc("已撤销", "Undone", "元に戻しました", "실행 취소됨")); Rebuild(); }

    private void MergeSelected(bool asNote)
    {
        var ids = _selection.ToList();
        if (ids.Count < (asNote ? 1 : 2)) { ShowToast(L10n.Loc("至少选 2 条", "Select 2+", "2件以上選択", "2개 이상 선택")); return; }
        PushUndo();
        _store.Merge(ids, asNote, asNote ? L10n.Loc("整理笔记", "Note", "ノート", "노트") : null);
        ShowToast(asNote ? L10n.Loc("已整理为笔记", "Saved as note", "ノートに保存しました", "노트로 저장됨") : L10n.Loc($"已合并 {ids.Count} 条", $"Merged {ids.Count}", $"{ids.Count}件を結合", $"{ids.Count}개 병합"));
        _selection.Clear(); Rebuild();
    }

    private void TagSelected()
    {
        var ids = _selection.ToList(); if (ids.Count == 0) return;
        var tag = Prompt(L10n.Loc("标签名:", "Tag:", "タグ名:", "태그 이름:"));
        if (string.IsNullOrWhiteSpace(tag)) return;
        PushUndo(); _store.ApplyTag(ids, tag.Trim());
        ShowToast(L10n.Loc($"已加标签 {ids.Count} 条", $"Tagged {ids.Count}", $"{ids.Count}件にタグ付け", $"{ids.Count}개 태그 추가")); _selection.Clear(); Rebuild();
    }

    private void DeleteSelected()
    {
        var ids = _selection.ToList(); if (ids.Count == 0) return;
        if (MessageBox.Show(this, L10n.Loc($"删除选中的 {ids.Count} 条?", $"Delete {ids.Count} records?", $"選択した{ids.Count}件を削除しますか?", $"선택한 {ids.Count}개를 삭제하시겠습니까?"), "Vibe XASR", MessageBoxButton.OKCancel, MessageBoxImage.Warning) != MessageBoxResult.OK) return;
        PushUndo(); foreach (var id in ids) _store.Delete(id);
        ShowToast(L10n.Loc($"已删除 {ids.Count} 条", $"Deleted {ids.Count}", $"{ids.Count}件を削除", $"{ids.Count}개 삭제")); _selection.Clear(); Rebuild();
    }

    private void CopySelected()
    {
        var ids = new HashSet<Guid>(_selection);
        var txt = string.Join("\n", _store.List().Where(e => ids.Contains(e.Id)).OrderBy(e => e.Timestamp).Select(e => e.Text));
        if (txt.Length > 0) { try { Clipboard.SetText(txt); } catch { } ShowToast(L10n.Loc($"已复制 {ids.Count} 条", $"Copied {ids.Count}", $"{ids.Count}件をコピー", $"{ids.Count}개 복사")); }
    }

    private void ClearAll()
    {
        if (_store.List().Count == 0) return;
        if (MessageBox.Show(this, L10n.Loc("清空全部记录?(可撤销)", "Clear all records? (undoable)", "すべての記録を消去しますか?(元に戻せます)", "모든 기록을 지우시겠습니까? (실행 취소 가능)"), "Vibe XASR", MessageBoxButton.OKCancel, MessageBoxImage.Warning) != MessageBoxResult.OK) return;
        PushUndo(); _store.ClearAll(); ShowToast(L10n.Loc("已清空", "Cleared", "消去しました", "지워짐")); _selection.Clear(); Rebuild();
    }

    private void ExportAll()
    {
        var dlg = new Microsoft.Win32.SaveFileDialog { FileName = "vibe-records.txt", Filter = "Text (*.txt)|*.txt|JSON (*.json)|*.json" };
        if (dlg.ShowDialog(this) != true) return;
        var asc = _store.List().OrderBy(e => e.Timestamp).ToList();
        try
        {
            bool json = Path.GetExtension(dlg.FileName).Equals(".json", StringComparison.OrdinalIgnoreCase);
            if (json)
            {
                var arr = asc.Select(e => new Dictionary<string, object> { ["date"] = e.Timestamp.ToString("o"), ["text"] = e.Text, ["mode"] = e.Mode, ["tags"] = e.Tags });
                File.WriteAllText(dlg.FileName, JsonSerializer.Serialize(arr, new JsonSerializerOptions { WriteIndented = true, Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping }));
            }
            else File.WriteAllText(dlg.FileName, string.Join("\n\n", asc.Select(e => $"{e.Timestamp.LocalDateTime:g}\n{e.Text}")));
            ShowToast(L10n.Loc($"已导出 {asc.Count} 条", $"Exported {asc.Count}", $"{asc.Count}件をエクスポート", $"{asc.Count}개 내보냄"));
        }
        catch (Exception ex) { MessageBox.Show(ex.Message); }
    }

    private void EditEntry(HistoryEntry e)
    {
        var dlg = new HistoryEditWindow(e, Zh) { Owner = this };
        if (dlg.ShowDialog() != true) return;
        PushUndo();
        if (string.IsNullOrWhiteSpace(dlg.ResultText)) _store.Delete(e.Id);
        else _store.Update(e.Id, dlg.ResultText, dlg.ResultTitle, dlg.ResultTags);
        Rebuild();
    }

    // ===================== helpers =====================

    private void RefreshExpiry()
    {
        // a record may have expired (ephemeral 60s) → rebuild if the count changed
        if (_store.List().Count != _flatIds.Count) Rebuild();
    }

    private void ShowToast(string msg)
    {
        ToastText.Text = msg; Toast.Visibility = Visibility.Visible;
        _toastTimer?.Stop();
        _toastTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(2200) };
        _toastTimer.Tick += (_, _) => { _toastTimer?.Stop(); Toast.Visibility = Visibility.Collapsed; };
        _toastTimer.Start();
    }

    private string? Prompt(string label)
    {
        var dlg = new HistoryPromptWindow(label) { Owner = this };
        return dlg.ShowDialog() == true ? dlg.Result : null;
    }

    private Style St(string key) => (Style)FindResource(key);
    private Brush Br(string key) => (Brush)FindResource(key);

    [DllImport("dwmapi.dll")] private static extern int DwmSetWindowAttribute(IntPtr h, int attr, ref int v, int size);
    private void DarkTitleBar() { try { var h = new WindowInteropHelper(this).Handle; int on = 1; DwmSetWindowAttribute(h, 20, ref on, sizeof(int)); } catch { } }

    private void SelfCapture()
    {
        var shot = Environment.GetEnvironmentVariable("VIBEXASR_SHOT");
        if (string.IsNullOrEmpty(shot)) return;
        Dispatcher.BeginInvoke(DispatcherPriority.Loaded, new Action(() =>
        {
            try
            {
                int w = (int)Math.Ceiling(ActualWidth), h = (int)Math.Ceiling(ActualHeight);
                var rtb = new System.Windows.Media.Imaging.RenderTargetBitmap(w, h, 96, 96, PixelFormats.Pbgra32);
                rtb.Render(this);
                var enc = new System.Windows.Media.Imaging.PngBitmapEncoder();
                enc.Frames.Add(System.Windows.Media.Imaging.BitmapFrame.Create(rtb));
                using var fs = File.Create(shot); enc.Save(fs);
            }
            catch { }
            if (System.Windows.Application.Current is { } a) a.Shutdown(); else Close();
        }));
    }
}
