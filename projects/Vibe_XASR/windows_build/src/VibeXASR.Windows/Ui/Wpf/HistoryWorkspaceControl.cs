using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Threading;
using VibeXASR.Windows.Storage;
using H = VibeXASR.Windows.Storage.HistoryClustering;
using Brush = System.Windows.Media.Brush;
using Brushes = System.Windows.Media.Brushes;
using Color = System.Windows.Media.Color;
using FontFamily = System.Windows.Media.FontFamily;
using Orientation = System.Windows.Controls.Orientation;
using HorizontalAlignment = System.Windows.HorizontalAlignment;
using VerticalAlignment = System.Windows.VerticalAlignment;
using Cursors = System.Windows.Input.Cursors;
using Clipboard = System.Windows.Clipboard;
using UserControl = System.Windows.Controls.UserControl;
using TextBox = System.Windows.Controls.TextBox;
using KeyEventArgs = System.Windows.Input.KeyEventArgs;

namespace VibeXASR.Windows.Ui.Wpf;

/// <summary>The full 记录 workspace, embedded as the Settings 记录 tab (100% port of macOS
/// HistoryWorkspace.swift): day-grouped fragment list with 碎句聚合 + one-click merge, multi-select +
/// bulk ops, topic tags, a mini calendar rail + month heatmap, search, keyboard flow and undo.
/// Drives <see cref="HistoryStore"/> directly via the UI-agnostic <see cref="H"/> clustering.</summary>
public sealed class HistoryWorkspaceControl : UserControl
{
    private readonly HistoryStore _store;
    private static bool Zh => L10n.Resolved is Lang.Zh or Lang.Hant;

    // palette (self-contained)
    private static SolidColorBrush Hex(string h) => new((Color)System.Windows.Media.ColorConverter.ConvertFromString(h));
    private static readonly Brush Surface = Hex("#15151B"), Surface2 = Hex("#1E1E26"), Text = Hex("#ECECF1"),
        Muted = Hex("#8A8A99"), Faint = Hex("#6A6A78"), AccentA = Hex("#7C5CFF"), AccentB = Hex("#38E1D6"),
        AccentSoft = Hex("#2A2342"), Success = Hex("#34D399"), Danger = Hex("#FF6B6B"),
        Hair = Hex("#22FFFFFF"), HairStrong = Hex("#33FFFFFF");
    private static readonly Brush AccentGrad = new LinearGradientBrush(
        (Color)System.Windows.Media.ColorConverter.ConvertFromString("#7C5CFF"),
        (Color)System.Windows.Media.ColorConverter.ConvertFromString("#38E1D6"), 45);
    private static readonly string[] TagPalette = { "#7C5CFF", "#5B8CFF", "#46C98B", "#E0894A", "#E05A8A", "#42B8C8", "#B07CF2", "#D0A92E" };

    // filter / view state
    private string _query = "";
    private string? _selectedDay, _tagFilter;
    private bool _aggregate = true, _showOnCall;
    private bool _calendarPane;
    private H.AggMode _aggMode = H.AggMode.Pause;
    private int _gapMin = 2, _targetChars = 120;
    private DateTime _monthCursor = DateTime.Today;
    private H.AggOptions Opts => new() { Mode = _aggMode, GapSeconds = _gapMin * 60, TargetChars = _targetChars };

    // selection + undo + keyboard focus
    private readonly HashSet<Guid> _selection = new();
    private readonly List<List<HistoryEntry>> _undo = new();
    private readonly HashSet<string> _expandedOC = new();
    private List<Guid> _flatIds = new();
    private int _lastClickIdx = -1, _focusIdx = -1;

    private readonly Grid _root = new();
    private DispatcherTimer? _toastTimer;
    private Border? _toast; private TextBlock? _toastText;
    private readonly Dictionary<Guid, Border> _rowCards = new();

    public HistoryWorkspaceControl(HistoryStore store)
    {
        _store = store;
        Background = Surface;
        Focusable = true;
        Content = _root;
        Rebuild();   // build immediately so it renders even before Loaded (dev screenshot path)
        Loaded += (_, _) => Keyboard.Focus(this);
        PreviewKeyDown += OnKey;
    }

    // ===================== rebuild =====================

    private void Rebuild()
    {
        var entries = _store.List();
        var filters = new H.Filters { ShowOnCall = _showOnCall, TagFilter = _tagFilter, Query = _query, SelectedDay = _selectedDay, Aggregate = _aggregate, Opts = Opts };
        var groups = H.BuildGroups(entries, filters);

        _flatIds = ComputeFlat(groups);
        var tags = AllTags(entries);
        var counts = DayCounts(entries);
        var clusterLists = ClusterLists(groups);

        _root.Children.Clear();
        _root.RowDefinitions.Clear();
        var col = new Grid();
        foreach (var _ in Enumerable.Range(0, 7)) col.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        col.RowDefinitions[5].Height = new GridLength(1, GridUnitType.Star);   // body fills

        Add(col, 0, Header(entries));
        Add(col, 1, Toolbar());
        if (tags.Count > 0) Add(col, 2, TagBar(tags));
        if (_selectedDay is { } sd) Add(col, 3, DayFilterBar(sd, entries));
        Add(col, 4, new Border { Height = 1, Background = Hair });
        Add(col, 5, Body(entries, groups, clusterLists, counts));
        Add(col, 6, ShortcutsBar());
        _root.Children.Add(col);

        // overlays: bulk bar + toast (bottom)
        if (_selection.Count > 0)
        {
            var bulk = BulkBar(entries, tags);
            bulk.HorizontalAlignment = HorizontalAlignment.Center; bulk.VerticalAlignment = VerticalAlignment.Bottom; bulk.Margin = new Thickness(0, 0, 0, 52);
            _root.Children.Add(bulk);
        }
        _toast = new Border { Visibility = Visibility.Collapsed, Background = Surface2, BorderBrush = HairStrong, BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(10), Padding = new Thickness(16, 10, 16, 10), HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Bottom, Margin = new Thickness(0, 0, 0, 110),
            Effect = new System.Windows.Media.Effects.DropShadowEffect { BlurRadius = 14, ShadowDepth = 8, Opacity = 0.3, Color = Colors.Black } };
        _toastText = new TextBlock { Foreground = Text, FontSize = 13 };
        _toast.Child = new StackPanel { Orientation = Orientation.Horizontal, Children = { new TextBlock { Text = "✓", Foreground = Success, FontSize = 13, Margin = new Thickness(0, 0, 8, 0), VerticalAlignment = VerticalAlignment.Center }, _toastText } };
        _root.Children.Add(_toast);
    }

    private static void Add(Grid g, int row, UIElement e) { Grid.SetRow(e, row); g.Children.Add(e); }

    // ===================== header =====================

    private FrameworkElement Header(IReadOnlyList<HistoryEntry> entries)
    {
        long chars = _store.LifetimeChars; int mins = (int)Math.Max(0, chars / 200);
        var bar = new Grid { Margin = new Thickness(20, 13, 20, 13) };
        bar.ColumnDefinitions.Add(new ColumnDefinition());
        bar.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var left = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
        var logo = new Border { Width = 30, Height = 30, CornerRadius = new CornerRadius(8), Background = AccentGrad };
        var lb = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
        foreach (var h in new double[] { 6, 12, 8 }) lb.Children.Add(new System.Windows.Shapes.Rectangle { Width = 2.5, Height = h, Fill = Brushes.White, RadiusX = 1.25, RadiusY = 1.25, Margin = new Thickness(1, 0, 1, 0) });
        logo.Child = lb; left.Children.Add(logo);
        left.Children.Add(new TextBlock { Text = L10n.T("history.title"), Foreground = Text, FontSize = 20, FontWeight = FontWeights.Bold, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(12, 0, 0, 0) });
        left.Children.Add(new TextBlock { Text = L10n.T("history.count", entries.Count), Foreground = Muted, FontSize = 13, FontWeight = FontWeights.Medium, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(10, 0, 0, 0) });
        left.Children.Add(new TextBlock { Text = L10n.Loc($"累计 {chars:N0} 字 · 省 {mins} 分", $"{chars:N0} chars · {mins} min saved", $"累計 {chars:N0} 文字 · {mins} 分節約", $"누적 {chars:N0}자 · {mins}분 절약"), Foreground = Muted, FontSize = 13, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(10, 0, 0, 0) });
        // OnCall checkbox
        left.Children.Add(OnCallCheck());
        Grid.SetColumn(left, 0); bar.Children.Add(left);

        var right = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
        right.Children.Add(UndoButton());
        var pill = new Border { CornerRadius = new CornerRadius(8), Background = new SolidColorBrush(Color.FromArgb(31, 0x34, 0xD3, 0x99)), Padding = new Thickness(11, 6, 11, 6), Margin = new Thickness(8, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center,
            Child = new StackPanel { Orientation = Orientation.Horizontal, Children = { new TextBlock { Text = "🔒 " + L10n.Loc("本地", "Local", "ローカル", "로컬"), Foreground = Success, FontSize = 12.5, FontWeight = FontWeights.SemiBold } } } };
        right.Children.Add(pill);
        right.Children.Add(GhostBtn("📤 " + L10n.Loc("导出", "Export", "エクスポート", "내보내기"), false, () => ExportAll(entries)));
        right.Children.Add(GhostBtn(L10n.Loc("全部清空", "Clear all", "すべて消去", "전체 지우기"), true, ClearAll));
        Grid.SetColumn(right, 1); bar.Children.Add(right);
        return new Border { Background = Surface2, Child = bar };
    }

    private FrameworkElement OnCallCheck()
    {
        var box = new Border { Width = 16, Height = 16, CornerRadius = new CornerRadius(5), Background = _showOnCall ? AccentA : Brushes.Transparent, BorderBrush = _showOnCall ? AccentA : HairStrong, BorderThickness = new Thickness(1.5), VerticalAlignment = VerticalAlignment.Center,
            Child = _showOnCall ? new TextBlock { Text = "✓", Foreground = Brushes.White, FontSize = 9, FontWeight = FontWeights.Bold, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center } : null };
        var sp = new StackPanel { Orientation = Orientation.Horizontal, Cursor = Cursors.Hand, Margin = new Thickness(12, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center };
        sp.Children.Add(box);
        sp.Children.Add(new TextBlock { Text = L10n.Loc("显示 OnCall 内容", "Show OnCall", "OnCall を表示", "OnCall 표시"), Foreground = _showOnCall ? Text : Muted, FontSize = 12, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(6, 0, 0, 0) });
        sp.MouseLeftButtonUp += (_, _) => { _showOnCall = !_showOnCall; Rebuild(); };
        return sp;
    }

    private FrameworkElement UndoButton()
    {
        bool can = _undo.Count > 0;
        var b = new Border { CornerRadius = new CornerRadius(8), Background = can ? AccentSoft : Surface2, BorderBrush = can ? AccentA : Brushes.Transparent, BorderThickness = new Thickness(1), Padding = new Thickness(13, 6, 13, 6), Cursor = can ? Cursors.Hand : Cursors.Arrow, VerticalAlignment = VerticalAlignment.Center,
            Child = new TextBlock { Text = "↶ " + L10n.Loc("撤销", "Undo", "元に戻す", "실행 취소"), Foreground = can ? AccentA : Faint, FontSize = 13, FontWeight = FontWeights.SemiBold } };
        if (can) b.MouseLeftButtonUp += (_, _) => Undo();
        return b;
    }

    // ===================== toolbar =====================

    private FrameworkElement Toolbar()
    {
        var row = new Grid { Margin = new Thickness(20, 11, 20, 11) };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });  // search
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });  // new
        row.ColumnDefinitions.Add(new ColumnDefinition());                            // spacer
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });  // agg + gear + pane

        var search = new Border { Width = 320, Height = 32, CornerRadius = new CornerRadius(8), Background = Surface2, BorderBrush = Hair, BorderThickness = new Thickness(1) };
        var sg = new Grid();
        sg.Children.Add(new TextBlock { Text = "🔍", FontSize = 12, Foreground = Faint, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(11, 0, 0, 0) });
        var tb = new TextBox { BorderThickness = new Thickness(0), Background = Brushes.Transparent, Foreground = Text, CaretBrush = AccentB, VerticalContentAlignment = VerticalAlignment.Center, FontSize = 13, Margin = new Thickness(30, 0, 8, 0), Text = _query };
        var ph = new TextBlock { Text = L10n.Loc("搜索记录…", "Search records…", "記録を検索…", "기록 검색…"), Foreground = Faint, FontSize = 13, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(32, 0, 0, 0), IsHitTestVisible = false, Visibility = string.IsNullOrEmpty(_query) ? Visibility.Visible : Visibility.Collapsed };
        tb.TextChanged += (_, _) => { _query = tb.Text; ph.Visibility = string.IsNullOrEmpty(_query) ? Visibility.Visible : Visibility.Collapsed; RebuildPreservingSearch(tb); };
        sg.Children.Add(tb); sg.Children.Add(ph); search.Child = sg;
        Grid.SetColumn(search, 0); row.Children.Add(search);

        var newBtn = GhostBtn("＋ " + L10n.Loc("新建", "New", "新規", "새로 만들기"), false, NewNote); newBtn.Margin = new Thickness(10, 0, 0, 0);
        Grid.SetColumn(newBtn, 1); row.Children.Add(newBtn);

        var rightSp = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right };
        rightSp.Children.Add(Chip("⛙ " + L10n.Loc("自动聚合", "Group", "グループ化", "그룹화"), _aggregate, () => { _aggregate = !_aggregate; Rebuild(); }));
        if (_aggregate)
        {
            var gear = new Border { CornerRadius = new CornerRadius(7), Background = Surface2, BorderBrush = Hair, BorderThickness = new Thickness(1), Padding = new Thickness(12, 5, 12, 5), Margin = new Thickness(8, 0, 0, 0), Cursor = Cursors.Hand,
                Child = new TextBlock { Text = (_aggMode == H.AggMode.Pause ? L10n.Loc($"停顿 ≤{_gapMin}分", $"Pause ≤{_gapMin}m", $"停止 ≤{_gapMin}分", $"멈춤 ≤{_gapMin}분") : L10n.Loc($"{_targetChars} 字", $"{_targetChars} chars", $"{_targetChars} 文字", $"{_targetChars}자")) + "  ⚙", Foreground = Muted, FontSize = 12, FontWeight = FontWeights.SemiBold } };
            var pop = AggPopover();
            gear.MouseLeftButtonUp += (_, _) => pop.IsOpen = !pop.IsOpen;
            rightSp.Children.Add(gear); rightSp.Children.Add(pop);
        }
        rightSp.Children.Add(PaneToggle());
        Grid.SetColumn(rightSp, 3); row.Children.Add(rightSp);

        return new Border { Background = Surface, BorderBrush = Hair, BorderThickness = new Thickness(0, 0, 0, 1), Child = row };
    }

    private void RebuildPreservingSearch(TextBox keep)
    {
        // rebuild but keep search focus + caret (search is the only live-typed field here)
        int caret = keep.CaretIndex;
        Rebuild();
        Dispatcher.BeginInvoke(DispatcherPriority.Input, new Action(() =>
        {
            var tb = FindSearchBox();
            if (tb is not null) { tb.Focus(); tb.CaretIndex = Math.Min(caret, tb.Text.Length); }
        }));
    }
    private TextBox? FindSearchBox() => Descendants(_root).OfType<TextBox>().FirstOrDefault();
    private static IEnumerable<DependencyObject> Descendants(DependencyObject root)
    {
        int n = VisualTreeHelper.GetChildrenCount(root);
        for (int i = 0; i < n; i++) { var c = VisualTreeHelper.GetChild(root, i); yield return c; foreach (var d in Descendants(c)) yield return d; }
    }

    private Popup AggPopover()
    {
        var pop = new Popup { Placement = PlacementMode.Bottom, StaysOpen = false, AllowsTransparency = true };
        var sp = new StackPanel { Margin = new Thickness(13) };
        sp.Children.Add(SegLabel(L10n.Loc("聚合方式", "Group by", "グループ化方法", "그룹화 방식")));
        sp.Children.Add(Seg(new[] { ("pause", L10n.Loc("按停顿", "By pause", "停止で", "멈춤")), ("chars", L10n.Loc("按字数", "By chars", "文字数で", "글자수")) }, _aggMode == H.AggMode.Pause ? "pause" : "chars",
            v => { var m = v == "chars" ? H.AggMode.Chars : H.AggMode.Pause; if (m != _aggMode) { _aggMode = m; Rebuild(); } }));
        if (_aggMode == H.AggMode.Pause)
        {
            sp.Children.Add(SegLabel(L10n.Loc("停顿阈值", "Pause threshold", "停止しきい値", "멈춤 임계값")));
            sp.Children.Add(Seg(new[] { 1, 2, 5, 10 }.Select(n => (n.ToString(), L10n.Loc($"≤{n}分", $"≤{n}m", $"≤{n}分", $"≤{n}분"))).ToArray(), _gapMin.ToString(), v => { if (int.TryParse(v, out var n) && n != _gapMin) { _gapMin = n; Rebuild(); } }));
        }
        else
        {
            sp.Children.Add(SegLabel(L10n.Loc("段落字数", "Paragraph size", "段落の文字数", "단락 글자수")));
            sp.Children.Add(Seg(new[] { 60, 120, 200, 300 }.Select(n => (n.ToString(), L10n.Loc($"{n}字", $"{n}c", $"{n}字", $"{n}자"))).ToArray(), _targetChars.ToString(), v => { if (int.TryParse(v, out var n) && n != _targetChars) { _targetChars = n; Rebuild(); } }));
        }
        pop.Child = new Border { Width = 260, Background = Surface2, BorderBrush = HairStrong, BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(10), Child = sp,
            Effect = new System.Windows.Media.Effects.DropShadowEffect { BlurRadius = 16, ShadowDepth = 4, Opacity = 0.4, Color = Colors.Black } };
        return pop;
    }
    private TextBlock SegLabel(string t) => new() { Text = t, Foreground = Muted, FontSize = 11.5, FontWeight = FontWeights.SemiBold, Margin = new Thickness(2, 6, 0, 6) };

    private FrameworkElement Seg((string val, string label)[] opts, string value, Action<string> onPick)
    {
        var outer = new Border { CornerRadius = new CornerRadius(7), Background = Surface, Padding = new Thickness(2) };
        var sp = new StackPanel { Orientation = Orientation.Horizontal };
        foreach (var (v, l) in opts)
        {
            bool sel = v == value;
            var seg = new Border { CornerRadius = new CornerRadius(5), Background = sel ? AccentSoft : Brushes.Transparent, Padding = new Thickness(12, 4, 12, 4), Cursor = Cursors.Hand, Child = new TextBlock { Text = l, Foreground = sel ? AccentA : Muted, FontSize = 11.5, FontWeight = sel ? FontWeights.SemiBold : FontWeights.Normal } };
            seg.MouseLeftButtonUp += (_, _) => onPick(v);
            sp.Children.Add(seg);
        }
        outer.Child = sp;
        return outer;
    }

    private FrameworkElement PaneToggle()
    {
        var outer = new Border { CornerRadius = new CornerRadius(7), Background = Surface2, Padding = new Thickness(2), Margin = new Thickness(8, 0, 0, 0) };
        var sp = new StackPanel { Orientation = Orientation.Horizontal };
        void Seg2(string label, bool sel, Action onClick)
        {
            var b = new Border { CornerRadius = new CornerRadius(5), Background = sel ? AccentSoft : Brushes.Transparent, Padding = new Thickness(12, 4, 12, 4), Cursor = Cursors.Hand, Child = new TextBlock { Text = label, Foreground = sel ? AccentA : Muted, FontSize = 12, FontWeight = sel ? FontWeights.SemiBold : FontWeights.Normal } };
            b.MouseLeftButtonUp += (_, _) => onClick();
            sp.Children.Add(b);
        }
        Seg2(L10n.Loc("列表", "List", "リスト", "목록"), !_calendarPane, () => { if (_calendarPane) { _calendarPane = false; Rebuild(); } });
        Seg2(L10n.Loc("日历", "Calendar", "カレンダー", "달력"), _calendarPane, () => { if (!_calendarPane) { _calendarPane = true; Rebuild(); } });
        outer.Child = sp;
        return outer;
    }

    private FrameworkElement Chip(string label, bool on, Action onClick)
    {
        var b = new Border { CornerRadius = new CornerRadius(7), Background = on ? AccentSoft : Surface2, BorderBrush = on ? AccentA : Hair, BorderThickness = new Thickness(1), Padding = new Thickness(12, 5, 12, 5), Cursor = Cursors.Hand,
            Child = new TextBlock { Text = label, Foreground = on ? Text : Muted, FontSize = 12.5, FontWeight = FontWeights.SemiBold } };
        b.MouseLeftButtonUp += (_, _) => onClick();
        return b;
    }

    // ===================== tag bar / day filter =====================

    private FrameworkElement TagBar(List<(string name, int count)> tags)
    {
        var sp = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(20, 9, 20, 9) };
        sp.Children.Add(new TextBlock { Text = "🏷", FontSize = 12, Foreground = Faint, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 8, 0) });
        var all = new Border { CornerRadius = new CornerRadius(12), Background = _tagFilter == null ? Text : Surface2, Padding = new Thickness(11, 3, 11, 3), Margin = new Thickness(0, 0, 8, 0), Cursor = Cursors.Hand,
            Child = new TextBlock { Text = L10n.Loc("全部", "All", "すべて", "전체"), Foreground = _tagFilter == null ? Surface : Muted, FontSize = 12, FontWeight = FontWeights.SemiBold } };
        all.MouseLeftButtonUp += (_, _) => { _tagFilter = null; Rebuild(); };
        sp.Children.Add(all);
        foreach (var (name, count) in tags) sp.Children.Add(TagChip(name, count, _tagFilter == name, () => { _tagFilter = _tagFilter == name ? null : name; Rebuild(); }));
        var scroll = new ScrollViewer { HorizontalScrollBarVisibility = ScrollBarVisibility.Hidden, VerticalScrollBarVisibility = ScrollBarVisibility.Disabled, Content = sp };
        return new Border { Background = Surface, BorderBrush = Hair, BorderThickness = new Thickness(0, 0, 0, 1), Child = scroll };
    }

    private FrameworkElement TagChip(string name, int? count, bool active, Action? onTap)
    {
        var c = TagColor(name);
        var sp = new StackPanel { Orientation = Orientation.Horizontal };
        sp.Children.Add(new System.Windows.Shapes.Ellipse { Width = 6, Height = 6, Fill = c, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 5, 0) });
        sp.Children.Add(new TextBlock { Text = name, Foreground = c, FontSize = 11.5, FontWeight = FontWeights.SemiBold, VerticalAlignment = VerticalAlignment.Center });
        if (count is { } n) sp.Children.Add(new TextBlock { Text = " " + n, Foreground = c, FontSize = 10.5, Opacity = 0.65, FontFamily = new FontFamily("Cascadia Mono, Consolas"), VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(4, 0, 0, 0) });
        var b = new Border { CornerRadius = new CornerRadius(12), Background = new SolidColorBrush(WithA(((SolidColorBrush)c).Color, 31)), BorderBrush = new SolidColorBrush(WithA(((SolidColorBrush)c).Color, active ? (byte)255 : (byte)84)), BorderThickness = new Thickness(active ? 1.5 : 1), Padding = new Thickness(8, 2, 8, 2), Margin = new Thickness(0, 0, 6, 0), Cursor = onTap != null ? Cursors.Hand : Cursors.Arrow, Child = sp };
        if (onTap != null) b.MouseLeftButtonUp += (_, e) => { e.Handled = true; onTap(); };
        return b;
    }

    private FrameworkElement DayFilterBar(string sd, IReadOnlyList<HistoryEntry> entries)
    {
        var g = new Grid { Margin = new Thickness(20, 10, 20, 10) };
        g.ColumnDefinitions.Add(new ColumnDefinition());
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var d = entries.FirstOrDefault(e => H.DayKey(e.Timestamp) == sd)?.Timestamp ?? DateTimeOffset.Now;
        var left = new StackPanel { Orientation = Orientation.Horizontal };
        left.Children.Add(new TextBlock { Text = "📅 " + L10n.Loc("正在查看 ", "Viewing ", "表示中 ", "보는 중 "), Foreground = AccentA, FontSize = 13, VerticalAlignment = VerticalAlignment.Center });
        left.Children.Add(new TextBlock { Text = DayLabel(sd, d), Foreground = Text, FontSize = 13, FontWeight = FontWeights.Bold, VerticalAlignment = VerticalAlignment.Center });
        g.Children.Add(left);
        var clear = GhostBtn(L10n.Loc("查看全部", "View all", "すべて表示", "전체 보기"), false, () => { _selectedDay = null; Rebuild(); });
        Grid.SetColumn(clear, 1); g.Children.Add(clear);
        return new Border { Background = AccentSoft, Child = g };
    }

    // ===================== body (list / calendar) =====================

    private FrameworkElement Body(IReadOnlyList<HistoryEntry> entries, List<H.DayGroup> groups, List<List<Guid>> clusterLists, Dictionary<string, int> counts)
    {
        var outer = new Grid();
        outer.ColumnDefinitions.Add(new ColumnDefinition());
        outer.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        FrameworkElement main;
        if (_calendarPane)
        {
            var cal = new ScrollViewer { VerticalScrollBarVisibility = ScrollBarVisibility.Auto, Content = new Border { Margin = new Thickness(20), Child = CalendarGrid(counts, 40) } };
            main = cal;
        }
        else
        {
            var list = new StackPanel { Margin = new Thickness(10, 0, 10, 0) };
            if (_aggregate && clusterLists.Count > 0) list.Children.Add(AggBanner(clusterLists));
            if (groups.Count == 0)
                list.Children.Add(new TextBlock { Text = "🔍\n\n" + (string.IsNullOrEmpty(_query) && _tagFilter == null ? L10n.Loc("还没有记录", "No records yet", "まだ記録がありません", "아직 기록이 없습니다") : L10n.Loc("没有匹配的记录", "No matching records", "一致する記録がありません", "일치하는 기록 없음")), Foreground = Muted, FontSize = 13, TextAlignment = TextAlignment.Center, HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 70, 0, 0) });
            _rowCards.Clear();
            foreach (var grp in groups)
            {
                list.Children.Add(DayHeader(grp, entries));
                foreach (var node in grp.Nodes) list.Children.Add(NodeView(node));
            }
            list.Children.Add(new Border { Height = 70 });
            main = new ScrollViewer { VerticalScrollBarVisibility = ScrollBarVisibility.Auto, Content = list };
        }
        Grid.SetColumn(main, 0); outer.Children.Add(main);

        if (!_calendarPane)
        {
            var rail = Rail(counts);
            Grid.SetColumn(rail, 1); outer.Children.Add(rail);
        }
        return outer;
    }

    private FrameworkElement AggBanner(List<List<Guid>> clusterLists)
    {
        int frags = clusterLists.Sum(c => c.Count);
        var g = new Grid { Margin = new Thickness(0, 8, 0, 8) };
        g.ColumnDefinitions.Add(new ColumnDefinition());
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var left = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
        left.Children.Add(new TextBlock { Text = "⛙", Foreground = AccentA, FontSize = 14, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 10, 0) });
        string head = _aggMode == H.AggMode.Pause
            ? L10n.Loc($"按 ≤{_gapMin} 分钟 停顿聚合 · 发现 ", $"Grouped by ≤{_gapMin}m pause · found ", $"≤{_gapMin}分 停止で集約 · ", $"≤{_gapMin}분 멈춤으로 묶음 · ")
            : L10n.Loc($"按 {_targetChars} 字 聚合 · 发现 ", $"Grouped by {_targetChars} chars · found ", $"{_targetChars}文字で集約 · ", $"{_targetChars}자로 묶음 · ");
        left.Children.Add(new TextBlock { Text = head + $"{clusterLists.Count}" + L10n.Loc($" 段连续碎句(共 {frags} 句)", $" clusters ({frags} frags)", $" 件の連続断片(計 {frags} 句)", $"개 묶음(총 {frags}구)"), Foreground = Text, FontSize = 13, VerticalAlignment = VerticalAlignment.Center, TextWrapping = TextWrapping.Wrap });
        g.Children.Add(left);
        var btn = new Border { CornerRadius = new CornerRadius(8), Background = AccentA, Padding = new Thickness(11, 6, 11, 6), Cursor = Cursors.Hand, VerticalAlignment = VerticalAlignment.Center,
            Child = new TextBlock { Text = "⛙ " + L10n.Loc($"全部合并 → {clusterLists.Count} 条", $"Merge all → {clusterLists.Count}", $"すべて結合 → {clusterLists.Count}", $"모두 병합 → {clusterLists.Count}"), Foreground = Brushes.White, FontSize = 12, FontWeight = FontWeights.SemiBold } };
        btn.MouseLeftButtonUp += (_, _) => { PushUndo(); foreach (var c in clusterLists) _store.Merge(c, false, null); ShowToast(L10n.Loc($"已合并 {clusterLists.Count} 段", $"Merged {clusterLists.Count}", $"{clusterLists.Count}件を結合", $"{clusterLists.Count}개 병합")); _selection.Clear(); Rebuild(); };
        Grid.SetColumn(btn, 1); g.Children.Add(btn);
        return new Border { CornerRadius = new CornerRadius(10), Background = AccentSoft, BorderBrush = AccentA, BorderThickness = new Thickness(1), Padding = new Thickness(14, 10, 14, 10), Margin = new Thickness(0, 4, 0, 8), Child = g };
    }

    private FrameworkElement DayHeader(H.DayGroup grp, IReadOnlyList<HistoryEntry> entries)
    {
        var g = new Grid { Margin = new Thickness(10, 8, 10, 8) };
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        g.ColumnDefinitions.Add(new ColumnDefinition());
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var lbl = new TextBlock { Text = DayLabel(grp.Key, grp.Date), Foreground = Muted, FontSize = 12.5, FontWeight = FontWeights.Bold, VerticalAlignment = VerticalAlignment.Center };
        Grid.SetColumn(lbl, 0); g.Children.Add(lbl);
        var cnt = new Border { CornerRadius = new CornerRadius(9), Background = Surface2, Padding = new Thickness(8, 2, 8, 2), Margin = new Thickness(8, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center, Child = new TextBlock { Text = L10n.T("history.count", grp.Count), Foreground = Faint, FontSize = 11 } };
        Grid.SetColumn(cnt, 1); g.Children.Add(cnt);
        var rule = new Border { Height = 1, Background = Hair, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(10, 0, 10, 0) };
        Grid.SetColumn(rule, 2); g.Children.Add(rule);
        var pick = new TextBlock { Text = "☑", Foreground = Faint, FontSize = 14, Cursor = Cursors.Hand, VerticalAlignment = VerticalAlignment.Center, ToolTip = L10n.Loc("选本天", "Select day", "この日を選択", "이 날 선택") };
        var ids = grp.Nodes.SelectMany(n => n.Items.Select(i => i.Id)).ToList();
        pick.MouseLeftButtonUp += (_, _) => { foreach (var id in ids) _selection.Add(id); Rebuild(); };
        Grid.SetColumn(pick, 3); g.Children.Add(pick);
        return new Border { Background = Surface, Child = g };
    }

    private FrameworkElement NodeView(H.HNode node)
    {
        switch (node.Kind)
        {
            case H.HNodeKind.Single: return FragRow(node.Items[0], canMerge: true);
            case H.HNodeKind.Cluster: return ClusterWrap(node);
            default: return OnCallBlock(node);
        }
    }

    private FrameworkElement ClusterWrap(H.HNode node)
    {
        int total = node.Items.Sum(i => H.CharCount(i.Text));
        var sp = new StackPanel { Margin = new Thickness(0, 2, 0, 2) };
        var head = new Grid { Margin = new Thickness(10, 6, 10, 4) };
        head.ColumnDefinitions.Add(new ColumnDefinition());
        head.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var hl = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
        hl.Children.Add(new Border { Width = 8, Height = 8, CornerRadius = new CornerRadius(2), BorderBrush = AccentA, BorderThickness = new Thickness(2), Margin = new Thickness(0, 0, 9, 0), VerticalAlignment = VerticalAlignment.Center });
        hl.Children.Add(new TextBlock { Text = L10n.Loc($"连续 {node.Items.Count} 句 · {total} 字", $"{node.Items.Count} frags · {total} chars", $"連続 {node.Items.Count} 句 · {total} 文字", $"연속 {node.Items.Count}구 · {total}자"), Foreground = Muted, FontSize = 11.5, FontWeight = FontWeights.SemiBold, VerticalAlignment = VerticalAlignment.Center });
        hl.Children.Add(new TextBlock { Text = "  " + L10n.Loc("停顿内聚合", "pause-grouped", "停止で集約", "멈춤 묶음"), Foreground = Faint, FontSize = 10.5, VerticalAlignment = VerticalAlignment.Center });
        head.Children.Add(hl);
        var ids = node.Items.Select(i => i.Id).ToList();
        var merge = GhostBtn("⛙ " + L10n.Loc("合并为一条", "Merge", "1件に結合", "하나로 병합"), false, () => { PushUndo(); _store.Merge(ids, false, null); ShowToast(L10n.Loc("已合并", "Merged", "結合しました", "병합됨")); _selection.Clear(); Rebuild(); });
        Grid.SetColumn(merge, 1); head.Children.Add(merge);
        sp.Children.Add(head);
        var kids = new StackPanel { Margin = new Thickness(20, 0, 0, 0) };
        foreach (var e in node.Items) kids.Children.Add(FragRow(e, canMerge: false));
        var kidsBorder = new Border { BorderBrush = HairStrong, BorderThickness = new Thickness(2, 0, 0, 0), Child = kids };
        sp.Children.Add(kidsBorder);
        return sp;
    }

    private FrameworkElement OnCallBlock(H.HNode node)
    {
        int total = node.Items.Sum(i => H.CharCount(i.Text));
        bool expanded = _expandedOC.Contains(node.Id);
        var sp = new StackPanel();
        var head = new Grid { Margin = new Thickness(12, 9, 12, 9) };
        head.ColumnDefinitions.Add(new ColumnDefinition());
        head.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var hl = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center, Cursor = Cursors.Hand };
        hl.Children.Add(new TextBlock { Text = expanded ? "▾" : "▸", Foreground = Muted, FontSize = 12, FontWeight = FontWeights.Bold, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 8, 0) });
        hl.Children.Add(new Border { CornerRadius = new CornerRadius(9), Background = AccentSoft, Padding = new Thickness(7, 1, 7, 1), Child = new TextBlock { Text = "OnCall", Foreground = AccentA, FontSize = 9.5, FontWeight = FontWeights.Bold } });
        hl.Children.Add(new TextBlock { Text = "  " + L10n.Loc($"{node.Items.Count} 句 · {total} 字", $"{node.Items.Count} frags · {total} chars", $"{node.Items.Count}句 · {total}文字", $"{node.Items.Count}구 · {total}자"), Foreground = Muted, FontSize = 12, VerticalAlignment = VerticalAlignment.Center });
        hl.MouseLeftButtonUp += (_, _) => { if (expanded) _expandedOC.Remove(node.Id); else _expandedOC.Add(node.Id); Rebuild(); };
        head.Children.Add(hl);
        var ids = node.Items.Select(i => i.Id).ToList();
        var del = new TextBlock { Text = "🗑", Foreground = Danger, FontSize = 13, Cursor = Cursors.Hand, VerticalAlignment = VerticalAlignment.Center, HorizontalAlignment = HorizontalAlignment.Right };
        del.MouseLeftButtonUp += (_, _) => { PushUndo(); foreach (var id in ids) _store.Delete(id); ShowToast(L10n.Loc("已删除", "Deleted", "削除しました", "삭제됨")); Rebuild(); };
        Grid.SetColumn(del, 1); head.Children.Add(del);
        sp.Children.Add(head);
        if (expanded)
        {
            var kids = new StackPanel { Margin = new Thickness(10, 0, 10, 6) };
            foreach (var e in node.Items) kids.Children.Add(FragRow(e, canMerge: false));
            sp.Children.Add(new Border { BorderBrush = Hair, BorderThickness = new Thickness(0, 1, 0, 0), Child = kids });
        }
        else
        {
            var preview = node.Items.FirstOrDefault()?.Text ?? "";
            if (preview.Length > 54) preview = preview[..54];
            sp.Children.Add(new TextBlock { Text = preview + L10n.Loc(" …点击展开", " …expand", " …展開", " …펼치기"), Foreground = Muted, FontSize = 13, FontFamily = new FontFamily("Cascadia Mono, Consolas"), Margin = new Thickness(34, 0, 12, 11), TextTrimming = TextTrimming.CharacterEllipsis });
        }
        return new Border { CornerRadius = new CornerRadius(10), Background = new SolidColorBrush(Color.FromArgb(128, 0x1E, 0x1E, 0x26)), BorderBrush = Hair, BorderThickness = new Thickness(1), Margin = new Thickness(0, 4, 0, 4), Child = sp };
    }

    private FrameworkElement FragRow(HistoryEntry e, bool canMerge)
    {
        bool selected = _selection.Contains(e.Id);
        int fi = _flatIds.IndexOf(e.Id);
        bool focused = fi >= 0 && fi == _focusIdx;

        var grid = new Grid { Margin = new Thickness(10, 8, 10, 8) };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition());
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        var check = new Border { Width = 18, Height = 18, CornerRadius = new CornerRadius(6), Background = selected ? AccentA : Brushes.Transparent, BorderBrush = selected ? AccentA : HairStrong, BorderThickness = new Thickness(1.6), VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(0, 2, 12, 0),
            Child = selected ? new TextBlock { Text = "✓", Foreground = Brushes.White, FontSize = 9, FontWeight = FontWeights.Bold, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center } : null,
            Opacity = selected || _selection.Count > 0 ? 1 : 0.0 };
        Grid.SetColumn(check, 0); grid.Children.Add(check);

        var body = new StackPanel();
        if (e.Title is { Length: > 0 } title) body.Children.Add(new TextBlock { Text = title, Foreground = AccentA, FontSize = 14, FontWeight = FontWeights.Bold, Margin = new Thickness(0, 0, 0, 3) });
        body.Children.Add(new TextBlock { Text = e.Text, Foreground = Text, FontFamily = new FontFamily("Cascadia Mono, Consolas"), FontSize = 13.5, TextWrapping = TextWrapping.Wrap, LineHeight = 19 });
        var meta = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 5, 0, 0) };
        meta.Children.Add(new TextBlock { Text = FullTime(e.Timestamp), Foreground = Faint, FontFamily = new FontFamily("Cascadia Mono, Consolas"), FontSize = 11, VerticalAlignment = VerticalAlignment.Center });
        if (H.CharCount(e.Text) <= 6) meta.Children.Add(new Border { CornerRadius = new CornerRadius(5), BorderBrush = Hair, BorderThickness = new Thickness(1), Padding = new Thickness(6, 1, 6, 1), Margin = new Thickness(9, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center, Child = new TextBlock { Text = L10n.Loc("碎句", "frag", "断片", "단편"), Foreground = Faint, FontSize = 10 } });
        foreach (var t in e.Tags) { meta.Children.Add(new Border { Margin = new Thickness(8, 0, 0, 0), Child = TagChip(t, null, false, null) }); }
        body.Children.Add(meta);
        Grid.SetColumn(body, 1); grid.Children.Add(body);

        // hover actions (col2)
        var act = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Top, Visibility = Visibility.Collapsed };
        act.Children.Add(IconAct("🏷", false, L10n.Loc("加标签", "Tag", "タグ", "태그"), () => TagOne(e.Id)));
        act.Children.Add(IconAct("⧉", false, L10n.Loc("复制", "Copy", "コピー", "복사"), () => { try { Clipboard.SetText(e.Text); } catch { } ShowToast(L10n.Loc("已复制", "Copied", "コピー", "복사됨")); }));
        act.Children.Add(IconAct("✎", false, L10n.Loc("编辑", "Edit", "編集", "편집"), () => EditEntry(e)));
        act.Children.Add(IconAct("🗑", true, L10n.Loc("删除", "Delete", "削除", "삭제"), () => { PushUndo(); _store.Delete(e.Id); _selection.Remove(e.Id); ShowToast(L10n.Loc("已删除", "Deleted", "削除", "삭제됨")); Rebuild(); }));
        if (canMerge && fi > 0) act.Children.Add(IconAct("⬆", false, L10n.Loc("并入上一条", "Merge up", "上に結合", "위로 병합"), () => MergeAdjacent(e.Id, -1)));
        if (canMerge && fi >= 0 && fi < _flatIds.Count - 1) act.Children.Add(IconAct("⬇", false, L10n.Loc("并入下一条", "Merge down", "下に結合", "아래로 병합"), () => MergeAdjacent(e.Id, +1)));
        Grid.SetColumn(act, 2); grid.Children.Add(act);

        var card = new Border { CornerRadius = new CornerRadius(9), Padding = new Thickness(0), Margin = new Thickness(0, 0, 0, 1), Background = selected ? AccentSoft : Brushes.Transparent, Cursor = Cursors.Hand, Child = grid };
        if (focused) { card.BorderBrush = AccentA; card.BorderThickness = new Thickness(1.5); }
        if (e.Title is { Length: > 0 }) card.BorderThickness = new Thickness(2, 0, 0, 0);
        card.MouseEnter += (_, _) => { act.Visibility = Visibility.Visible; if (!selected) card.Background = new SolidColorBrush(Color.FromArgb(90, 0x1E, 0x1E, 0x26)); check.Opacity = 1; };
        card.MouseLeave += (_, _) => { act.Visibility = Visibility.Collapsed; if (!selected) card.Background = Brushes.Transparent; check.Opacity = selected || _selection.Count > 0 ? 1 : 0; };
        bool suppress = false;
        card.PreviewMouseLeftButtonDown += (_, ev) => { if (ev.ClickCount == 2) { suppress = true; ev.Handled = true; EditEntry(e); } };
        card.MouseLeftButtonUp += (_, ev) =>
        {
            if (suppress) { suppress = false; return; }
            if (ev.OriginalSource is FrameworkElement fe && IsActionElement(fe)) return;
            Toggle(e.Id, (Keyboard.Modifiers & ModifierKeys.Shift) != 0);
        };
        _rowCards[e.Id] = card;
        return card;
    }

    private static bool IsActionElement(FrameworkElement fe)
    {
        DependencyObject? d = fe;
        while (d is not null) { if (d is Border b && b.Cursor == Cursors.Hand && b.Child is TextBlock) return true; d = VisualTreeHelper.GetParent(d); }
        return false;
    }

    private Border IconAct(string glyph, bool danger, string tip, Action onClick)
    {
        var b = new Border { CornerRadius = new CornerRadius(7), Background = Brushes.Transparent, Padding = new Thickness(6, 3, 6, 3), Margin = new Thickness(2, 0, 0, 0), Cursor = Cursors.Hand, ToolTip = tip, Child = new TextBlock { Text = glyph, FontSize = 13, Foreground = danger ? Danger : Faint } };
        b.MouseEnter += (_, _) => b.Background = Surface2;
        b.MouseLeave += (_, _) => b.Background = Brushes.Transparent;
        b.MouseLeftButtonUp += (_, e) => { e.Handled = true; onClick(); };
        return b;
    }

    // ===================== rail / calendar =====================

    private FrameworkElement Rail(Dictionary<string, int> counts)
    {
        var monthPrefix = $"{_monthCursor.Year}-{_monthCursor.Month}-";   // matches H.DayKey "2026-6-6" (unpadded)
        int monthCount = counts.Where(kv => kv.Key.StartsWith(monthPrefix)).Sum(kv => kv.Value);
        var sp = new StackPanel { Margin = new Thickness(16) };
        sp.Children.Add(new TextBlock { Text = "📅 " + L10n.Loc("日历", "CALENDAR", "カレンダー", "달력"), Foreground = Muted, FontSize = 12, FontWeight = FontWeights.Bold, Margin = new Thickness(0, 0, 0, 12) });
        sp.Children.Add(CalendarGrid(counts, 26));
        var stats = new StackPanel { Margin = new Thickness(0, 14, 0, 0) };
        stats.Children.Add(RailStat(L10n.Loc("本月记录", "This month", "今月の記録", "이번 달 기록"), L10n.T("history.count", monthCount)));
        stats.Children.Add(RailStat(L10n.Loc("活跃天数", "Active days", "アクティブ日数", "활동 일수"), L10n.Loc($"{counts.Count} 天", $"{counts.Count} d", $"{counts.Count}日", $"{counts.Count}일")));
        sp.Children.Add(new Border { BorderBrush = Hair, BorderThickness = new Thickness(0, 1, 0, 0), Margin = new Thickness(0, 4, 0, 0), Padding = new Thickness(0, 10, 0, 0), Child = stats });
        return new Border { Width = 262, Background = Surface2, BorderBrush = Hair, BorderThickness = new Thickness(1, 0, 0, 0), Child = new ScrollViewer { VerticalScrollBarVisibility = ScrollBarVisibility.Auto, Content = sp } };
    }

    private FrameworkElement RailStat(string label, string value)
    {
        var g = new Grid { Margin = new Thickness(0, 0, 0, 9) };
        g.ColumnDefinitions.Add(new ColumnDefinition());
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        g.Children.Add(new TextBlock { Text = label, Foreground = Muted, FontSize = 12.5 });
        var v = new TextBlock { Text = value, Foreground = Text, FontSize = 12.5, FontWeight = FontWeights.Bold, FontFamily = new FontFamily("Cascadia Mono, Consolas") };
        Grid.SetColumn(v, 1); g.Children.Add(v);
        return g;
    }

    private FrameworkElement CalendarGrid(Dictionary<string, int> counts, double cell)
    {
        int max = counts.Count > 0 ? counts.Values.Max() : 1;
        var root = new StackPanel();
        var hdr = new Grid { Margin = new Thickness(0, 0, 0, 8) };
        hdr.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        hdr.ColumnDefinitions.Add(new ColumnDefinition());
        hdr.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        hdr.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var prev = new TextBlock { Text = "‹", Foreground = AccentA, FontSize = 16, Cursor = Cursors.Hand, VerticalAlignment = VerticalAlignment.Center };
        prev.MouseLeftButtonUp += (_, _) => { _monthCursor = _monthCursor.AddMonths(-1); Rebuild(); };
        Grid.SetColumn(prev, 0); hdr.Children.Add(prev);
        var title = new TextBlock { Text = L10n.Loc($"{_monthCursor.Year} 年 {_monthCursor.Month} 月", _monthCursor.ToString("MMMM yyyy", CultureInfo.InvariantCulture), $"{_monthCursor.Year}年{_monthCursor.Month}月", $"{_monthCursor.Year}년 {_monthCursor.Month}월"), Foreground = Text, FontSize = 12.5, FontWeight = FontWeights.SemiBold, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
        Grid.SetColumn(title, 1); hdr.Children.Add(title);
        var today = new TextBlock { Text = L10n.Loc("今天", "Today", "今日", "오늘"), Foreground = Muted, FontSize = 11, Cursor = Cursors.Hand, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 8, 0) };
        today.MouseLeftButtonUp += (_, _) => { _monthCursor = DateTime.Today; Rebuild(); };
        Grid.SetColumn(today, 2); hdr.Children.Add(today);
        var next = new TextBlock { Text = "›", Foreground = AccentA, FontSize = 16, Cursor = Cursors.Hand, VerticalAlignment = VerticalAlignment.Center };
        next.MouseLeftButtonUp += (_, _) => { _monthCursor = _monthCursor.AddMonths(1); Rebuild(); };
        Grid.SetColumn(next, 3); hdr.Children.Add(next);
        root.Children.Add(hdr);

        var uni = new UniformGrid { Columns = 7 };
        string[] wk = Zh ? new[] { "一", "二", "三", "四", "五", "六", "日" } : new[] { "M", "T", "W", "T", "F", "S", "S" };
        foreach (var w in wk) uni.Children.Add(new TextBlock { Text = w, Foreground = Faint, FontSize = 10, HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 0, 0, 3) });
        foreach (var d in H.MonthGrid(_monthCursor))
        {
            string key = H.DayKey(new DateTimeOffset(d));
            int n = counts.TryGetValue(key, out var c) ? c : 0;
            bool thisMonth = d.Month == _monthCursor.Month, isSel = _selectedDay == key;
            var box = new Border { CornerRadius = new CornerRadius(5), Margin = new Thickness(2), Height = cell, Background = HeatBrush(H.HeatLevel(n, max)), Cursor = Cursors.Hand, BorderBrush = isSel ? AccentB : Brushes.Transparent, BorderThickness = new Thickness(isSel ? 1.6 : 0), Opacity = thisMonth ? 1 : 0.32,
                Child = new TextBlock { Text = d.Day.ToString(), Foreground = n > 0 ? Brushes.White : Faint, FontSize = 10.5, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center } };
            var ck = key;
            box.MouseLeftButtonUp += (_, _) => { _selectedDay = _selectedDay == ck ? null : ck; _calendarPane = false; Rebuild(); };
            uni.Children.Add(box);
        }
        root.Children.Add(uni);
        return root;
    }

    private Brush HeatBrush(int level) => level switch
    {
        0 => Surface,
        1 => new SolidColorBrush(Color.FromArgb(70, 0x7C, 0x5C, 0xFF)),
        2 => new SolidColorBrush(Color.FromArgb(130, 0x7C, 0x5C, 0xFF)),
        3 => new SolidColorBrush(Color.FromArgb(190, 0x7C, 0x5C, 0xFF)),
        _ => new SolidColorBrush(Color.FromArgb(240, 0x7C, 0x5C, 0xFF)),
    };

    // ===================== shortcuts + bulk + toast =====================

    private FrameworkElement ShortcutsBar()
    {
        var sp = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(20, 7, 20, 7) };
        void Kb(string keys, string label) { sp.Children.Add(new Border { CornerRadius = new CornerRadius(5), Background = Surface2, BorderBrush = HairStrong, BorderThickness = new Thickness(1), Padding = new Thickness(5, 1, 5, 1), Margin = new Thickness(0, 0, 5, 0), Child = new TextBlock { Text = keys, Foreground = Muted, FontFamily = new FontFamily("Cascadia Mono, Consolas"), FontSize = 10.5 } }); sp.Children.Add(new TextBlock { Text = label, Foreground = Faint, FontSize = 11, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 14, 0) }); }
        Kb("J K", L10n.Loc("移动", "move", "移動", "이동")); Kb("X", L10n.Loc("选择", "select", "選択", "선택")); Kb("E", L10n.Loc("编辑", "edit", "編集", "편집"));
        Kb("D", L10n.Loc("删除", "delete", "削除", "삭제")); Kb("M", L10n.Loc("合并所选", "merge", "結合", "병합")); Kb("A", L10n.Loc("全选", "all", "全選択", "전체")); Kb("Esc", L10n.Loc("取消", "cancel", "取消", "취소"));
        var hint = new TextBlock { Text = L10n.Loc("Shift+点击 选范围", "Shift+click for range", "Shift+クリックで範囲", "Shift+클릭 범위"), Foreground = Faint, FontSize = 11, HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Center };
        var g = new Grid(); g.ColumnDefinitions.Add(new ColumnDefinition()); g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        Grid.SetColumn(sp, 0); g.Children.Add(sp); Grid.SetColumn(hint, 1); g.Children.Add(hint);
        return new Border { Background = Surface2, BorderBrush = Hair, BorderThickness = new Thickness(0, 1, 0, 0), Child = new Grid { Margin = new Thickness(20, 0, 20, 0), Children = { g } } };
    }

    private FrameworkElement BulkBar(IReadOnlyList<HistoryEntry> entries, List<(string name, int count)> tags)
    {
        var ids = _selection.ToList();
        var sp = new StackPanel { Orientation = Orientation.Horizontal };
        sp.Children.Add(new Border { Width = 22, Height = 22, CornerRadius = new CornerRadius(11), Background = AccentA, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(4, 0, 8, 0), Child = new TextBlock { Text = _selection.Count.ToString(), Foreground = Brushes.White, FontSize = 12, FontWeight = FontWeights.Bold, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center } });
        sp.Children.Add(new TextBlock { Text = L10n.Loc("已选", "selected", "選択", "선택됨"), Foreground = Text, FontSize = 13, FontWeight = FontWeights.Bold, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 10, 0) });
        void D() => sp.Children.Add(new Border { Width = 1, Height = 22, Background = HairStrong, Margin = new Thickness(0, 0, 8, 0), VerticalAlignment = VerticalAlignment.Center });
        D();
        sp.Children.Add(GhostBtn("⛙ " + L10n.Loc("合并", "Merge", "結合", "병합"), false, () => MergeSelected(false)));
        sp.Children.Add(GhostBtn("📝 " + L10n.Loc("整理成笔记", "To note", "ノートに", "노트로"), false, () => MergeSelected(true)));
        sp.Children.Add(GhostBtn("🏷 " + L10n.Loc("加标签", "Tag", "タグ", "태그"), false, () => TagMany(ids)));
        sp.Children.Add(GhostBtn("⧉ " + L10n.Loc("复制", "Copy", "コピー", "복사"), false, () => CopySelected()));
        D();
        sp.Children.Add(GhostBtn("🗑 " + L10n.Loc("删除", "Delete", "削除", "삭제"), true, () => DeleteSelected()));
        var x = new TextBlock { Text = "✕", Foreground = Muted, FontSize = 13, Cursor = Cursors.Hand, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(6, 0, 4, 0) };
        x.MouseLeftButtonUp += (_, _) => { _selection.Clear(); Rebuild(); };
        sp.Children.Add(x);
        return new Border { CornerRadius = new CornerRadius(12), Background = Surface2, BorderBrush = HairStrong, BorderThickness = new Thickness(1), Padding = new Thickness(10, 8, 10, 8), Child = sp,
            Effect = new System.Windows.Media.Effects.DropShadowEffect { BlurRadius = 18, ShadowDepth = 10, Opacity = 0.35, Color = Colors.Black } };
    }

    private Border GhostBtn(string label, bool danger, Action onClick)
    {
        var b = new Border { CornerRadius = new CornerRadius(8), Background = danger ? Brushes.Transparent : Surface2, BorderBrush = danger ? Brushes.Transparent : HairStrong, BorderThickness = new Thickness(1), Padding = new Thickness(10, 5, 10, 5), Margin = new Thickness(0, 0, 6, 0), Cursor = Cursors.Hand, VerticalAlignment = VerticalAlignment.Center,
            Child = new TextBlock { Text = label, Foreground = danger ? Danger : Text, FontSize = 12, FontWeight = FontWeights.SemiBold } };
        b.MouseLeftButtonUp += (_, _) => onClick();
        return b;
    }

    private void ShowToast(string msg)
    {
        if (_toast is null || _toastText is null) return;
        _toastText.Text = msg; _toast.Visibility = Visibility.Visible;
        _toastTimer?.Stop();
        _toastTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(2200) };
        _toastTimer.Tick += (_, _) => { _toastTimer?.Stop(); if (_toast is not null) _toast.Visibility = Visibility.Collapsed; };
        _toastTimer.Start();
    }

    // ===================== mutations =====================

    private void PushUndo() { _undo.Add(_store.Snapshot()); if (_undo.Count > 12) _undo.RemoveAt(0); }
    private void Undo() { if (_undo.Count == 0) return; var s = _undo[^1]; _undo.RemoveAt(_undo.Count - 1); _store.Restore(s); _selection.Clear(); ShowToast(L10n.Loc("已撤销", "Undone", "元に戻しました", "실행 취소됨")); Rebuild(); }
    private void Toggle(Guid id, bool shift)
    {
        if (shift && _lastClickIdx >= 0)
        {
            int idx = _flatIds.IndexOf(id);
            if (idx >= 0) for (int i = Math.Min(_lastClickIdx, idx); i <= Math.Max(_lastClickIdx, idx); i++) if (i < _flatIds.Count) _selection.Add(_flatIds[i]);
        }
        else { if (_selection.Contains(id)) _selection.Remove(id); else _selection.Add(id); _lastClickIdx = _flatIds.IndexOf(id); }
        Rebuild();
    }
    private void MergeAdjacent(Guid id, int dir)
    {
        int i = _flatIds.IndexOf(id), j = i + dir;
        if (i < 0 || j < 0 || j >= _flatIds.Count) return;
        PushUndo(); _store.Merge(new[] { _flatIds[Math.Min(i, j)], _flatIds[Math.Max(i, j)] }, false, null);
        ShowToast(L10n.Loc("已合并", "Merged", "結合しました", "병합됨")); _selection.Clear(); Rebuild();
    }
    private void MergeSelected(bool asNote)
    {
        var ids = _selection.ToList();
        if (ids.Count < (asNote ? 1 : 2)) { ShowToast(L10n.Loc("至少选 2 条", "Select 2+", "2件以上選択", "2개 이상")); return; }
        PushUndo(); _store.Merge(ids, asNote, asNote ? L10n.Loc("整理笔记", "Note", "ノート", "노트") : null);
        ShowToast(asNote ? L10n.Loc("已整理为笔记", "Saved as note", "ノートにしました", "노트로 저장") : L10n.Loc("已合并", "Merged", "結合しました", "병합됨")); _selection.Clear(); Rebuild();
    }
    private void TagOne(Guid id) => TagMany(new List<Guid> { id });
    private void TagMany(List<Guid> ids)
    {
        if (ids.Count == 0) return;
        var dlg = new HistoryPromptWindow(L10n.Loc("标签名:", "Tag:", "タグ名:", "태그명:")) { Owner = Window.GetWindow(this) };
        if (dlg.ShowDialog() != true || string.IsNullOrWhiteSpace(dlg.Result)) return;
        PushUndo(); _store.ApplyTag(ids, dlg.Result.Trim()); ShowToast(L10n.Loc("已加标签", "Tagged", "タグ付け", "태그됨")); _selection.Clear(); Rebuild();
    }
    private void CopySelected()
    {
        var set = new HashSet<Guid>(_selection);
        var txt = string.Join("\n", _store.List().Where(e => set.Contains(e.Id)).OrderBy(e => e.Timestamp).Select(e => e.Text));
        if (txt.Length > 0) { try { Clipboard.SetText(txt); } catch { } ShowToast(L10n.Loc("已复制", "Copied", "コピー", "복사됨")); }
    }
    private void DeleteSelected()
    {
        var ids = _selection.ToList(); if (ids.Count == 0) return;
        if (System.Windows.MessageBox.Show(Window.GetWindow(this), L10n.Loc($"删除选中的 {ids.Count} 条?", $"Delete {ids.Count} records?", $"{ids.Count}件を削除?", $"{ids.Count}개 삭제?"), "Vibe XASR", System.Windows.MessageBoxButton.OKCancel, System.Windows.MessageBoxImage.Warning) != System.Windows.MessageBoxResult.OK) return;
        PushUndo(); foreach (var id in ids) _store.Delete(id); ShowToast(L10n.Loc("已删除", "Deleted", "削除", "삭제됨")); _selection.Clear(); Rebuild();
    }
    private void ClearAll()
    {
        if (_store.List().Count == 0) return;
        if (System.Windows.MessageBox.Show(Window.GetWindow(this), L10n.Loc("清空全部记录?(可撤销)", "Clear all records? (undoable)", "すべて消去?(取消可)", "전체 지우기?(취소 가능)"), "Vibe XASR", System.Windows.MessageBoxButton.OKCancel, System.Windows.MessageBoxImage.Warning) != System.Windows.MessageBoxResult.OK) return;
        PushUndo(); _store.ClearAll(); ShowToast(L10n.Loc("已清空", "Cleared", "消去しました", "지워짐")); _selection.Clear(); Rebuild();
    }
    private void NewNote()
    {
        PushUndo(); var id = _store.AddEntry();
        var e = _store.List().FirstOrDefault(x => x.Id == id);
        if (e is not null) EditEntry(e); else Rebuild();
    }
    private void EditEntry(HistoryEntry e)
    {
        var dlg = new HistoryEditWindow(e, Zh) { Owner = Window.GetWindow(this) };
        if (dlg.ShowDialog() != true) { Rebuild(); return; }
        PushUndo();
        if (string.IsNullOrWhiteSpace(dlg.ResultText)) _store.Delete(e.Id);
        else _store.Update(e.Id, dlg.ResultText, dlg.ResultTitle, dlg.ResultTags);
        Rebuild();
    }
    private void ExportAll(IReadOnlyList<HistoryEntry> _)
    {
        var dlg = new Microsoft.Win32.SaveFileDialog { FileName = "vibe-records.txt", Filter = "Text (*.txt)|*.txt|JSON (*.json)|*.json" };
        if (dlg.ShowDialog() != true) return;
        var asc = _store.List().OrderBy(e => e.Timestamp).ToList();
        try
        {
            if (System.IO.Path.GetExtension(dlg.FileName).Equals(".json", StringComparison.OrdinalIgnoreCase))
            {
                var arr = asc.Select(e => new Dictionary<string, object> { ["date"] = e.Timestamp.ToString("o"), ["text"] = e.Text, ["mode"] = e.Mode, ["tags"] = e.Tags });
                System.IO.File.WriteAllText(dlg.FileName, System.Text.Json.JsonSerializer.Serialize(arr, new System.Text.Json.JsonSerializerOptions { WriteIndented = true, Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping }));
            }
            else System.IO.File.WriteAllText(dlg.FileName, string.Join("\n\n", asc.Select(e => $"{e.Timestamp.LocalDateTime:g}\n{e.Text}")));
            ShowToast(L10n.Loc($"已导出 {asc.Count} 条", $"Exported {asc.Count}", $"{asc.Count}件をエクスポート", $"{asc.Count}개 내보냄"));
        }
        catch { ShowToast(L10n.Loc("导出失败", "Export failed", "エクスポート失敗", "내보내기 실패")); }
    }

    // ===================== keyboard =====================

    private void OnKey(object sender, KeyEventArgs e)
    {
        if (Keyboard.FocusedElement is TextBox) return;   // typing in search/editor
        if (_calendarPane) return;
        bool handled = true;
        switch (e.Key)
        {
            case Key.J: MoveFocus(+1); break;
            case Key.K: MoveFocus(-1); break;
            case Key.X: if (Focused() is { } fx) Toggle(fx, false); break;
            case Key.E: if (Focused() is { } fe2 && _store.List().FirstOrDefault(x => x.Id == fe2) is { } en) EditEntry(en); break;
            case Key.D: if (_selection.Count > 0) DeleteSelected(); else if (Focused() is { } fd) { PushUndo(); _store.Delete(fd); ShowToast(L10n.Loc("已删除", "Deleted", "削除", "삭제됨")); Rebuild(); } break;
            case Key.M: MergeSelected(false); break;
            case Key.A: foreach (var id in _flatIds) _selection.Add(id); Rebuild(); break;
            case Key.Escape: _selection.Clear(); _focusIdx = -1; Rebuild(); break;
            default: handled = false; break;
        }
        if (handled) e.Handled = true;
    }
    private Guid? Focused() => _focusIdx >= 0 && _focusIdx < _flatIds.Count ? _flatIds[_focusIdx] : null;
    private void MoveFocus(int d)
    {
        if (_flatIds.Count == 0) return;
        _focusIdx = Math.Max(0, Math.Min(_flatIds.Count - 1, (_focusIdx < 0 ? 0 : _focusIdx + d)));
        Rebuild();
        if (Focused() is { } id && _rowCards.TryGetValue(id, out var card)) Dispatcher.BeginInvoke(DispatcherPriority.Background, new Action(() => card.BringIntoView()));
    }

    // ===================== derivations / helpers =====================

    private List<Guid> ComputeFlat(List<H.DayGroup> groups)
    {
        var ids = new List<Guid>();
        foreach (var g in groups)
            foreach (var n in g.Nodes)
            {
                if (n.Kind == H.HNodeKind.OnCall && !_expandedOC.Contains(n.Id)) continue;
                foreach (var it in n.Items) ids.Add(it.Id);
            }
        return ids;
    }
    private static Dictionary<string, int> DayCounts(IReadOnlyList<HistoryEntry> entries)
    {
        var c = new Dictionary<string, int>();
        foreach (var e in entries) { var k = H.DayKey(e.Timestamp); c[k] = c.TryGetValue(k, out var v) ? v + 1 : 1; }
        return c;
    }
    private static List<(string name, int count)> AllTags(IReadOnlyList<HistoryEntry> entries)
    {
        var m = new Dictionary<string, int>();
        foreach (var e in entries) foreach (var t in e.Tags) m[t] = m.TryGetValue(t, out var v) ? v + 1 : 1;
        return m.OrderByDescending(kv => kv.Value).Select(kv => (kv.Key, kv.Value)).ToList();
    }
    private static List<List<Guid>> ClusterLists(List<H.DayGroup> groups)
    {
        var outl = new List<List<Guid>>();
        foreach (var g in groups) foreach (var n in g.Nodes) if (n.Kind == H.HNodeKind.Cluster) outl.Add(n.Items.Select(i => i.Id).ToList());
        return outl;
    }

    private Brush TagColor(string name)
    {
        uint h = 0; foreach (var ch in name) h = h * 31 + ch;
        return Hex(TagPalette[(int)(h % (uint)TagPalette.Length)]);
    }
    private static Color WithA(Color c, byte a) => Color.FromArgb(a, c.R, c.G, c.B);

    private string DayLabel(string key, DateTimeOffset d)
    {
        var todayK = H.DayKey(DateTimeOffset.Now);
        var yestK = H.DayKey(DateTimeOffset.Now.AddDays(-1));
        if (key == todayK) return L10n.Loc("今天", "Today", "今日", "오늘");
        if (key == yestK) return L10n.Loc("昨天", "Yesterday", "昨日", "어제");
        return d.LocalDateTime.ToString(Zh ? "M月d日 ddd" : "MMM d, ddd", CultureInfo.GetCultureInfo(Zh ? "zh-CN" : "en-US"));
    }
    private string FullTime(DateTimeOffset d)
    {
        var lt = d.LocalDateTime;
        if (Zh)
        {
            string ap = lt.Hour < 12 ? "上午" : "下午"; int h = lt.Hour % 12; if (h == 0) h = 12;
            return $"{lt:yyyy年M月d日} {ap}{h}:{lt.Minute:D2}";
        }
        return lt.ToString("g", CultureInfo.CurrentCulture);
    }
}
