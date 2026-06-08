using System;
using System.Linq;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Effects;
using System.Windows.Shapes;
using System.Windows.Threading;
using VibeXASR.Windows.Storage;
using Brush = System.Windows.Media.Brush;
using Brushes = System.Windows.Media.Brushes;
using Color = System.Windows.Media.Color;
using FontFamily = System.Windows.Media.FontFamily;
using Orientation = System.Windows.Controls.Orientation;
using HorizontalAlignment = System.Windows.HorizontalAlignment;
using VerticalAlignment = System.Windows.VerticalAlignment;
using Cursors = System.Windows.Input.Cursors;
using Rectangle = System.Windows.Shapes.Rectangle;
using Ellipse = System.Windows.Shapes.Ellipse;

namespace VibeXASR.Windows.Ui.Wpf;

/// <summary>Borderless, top-most, never-activating overlay (WPF port of OverlayForm). Two states:
///  • HUD (push-to-talk): a rounded glass pill near the bottom centre with an accent orb,
///    a center-weighted reactive waveform, the streaming text + blinking caret, and a timer.
///    Click-through so the target app keeps focus. Also covers Inserted / Refining confirmations.
///  • OnCall: a top-right interactive panel with red dot + timer, live transcript, and
///    Copy / View / Pause / Stop pills.</summary>
public sealed class OverlayWindow : Window
{
    public enum OverlayState { Hidden, Listening, Inserted, OnCall, Refining }

    private OverlayState _state = OverlayState.Hidden;
    private string _text = string.Empty;
    private double _level;
    private DateTime _startedAt = DateTime.Now;
    private bool _paused;

    // Overlay-stay duration (macOS build 204 parity): how long the "已插入" confirm lingers, and
    // hover-to-keep. Driven by Settings.HudStaySeconds via SetStaySeconds().
    private double _staySeconds = 0.5;
    private DispatcherTimer? _hideTimer;

    private readonly double[] _bars = new double[20];
    private readonly Random _rng = new();
    private readonly DispatcherTimer _anim = new() { Interval = TimeSpan.FromMilliseconds(45) };
    private int _blinkTick;

    // live visual refs (rebuilt per state)
    private readonly Rectangle[] _barRects = new Rectangle[20];
    private TextBlock? _streamText, _caret, _timerText, _onCallBody, _onCallTimer;
    private Grid? _hudGrid;   // for measuring the stream-text column width (head-clip long text)
    private Ellipse? _orbGlow;

    public event EventHandler? CopyRequested;
    public event EventHandler? StopRequested;
    public event EventHandler? ViewRequested;
    public event EventHandler? PauseRequested;
    public event EventHandler? UndoRequested;          // post-insert: delete the just-inserted text
    public event EventHandler<string>? RepolishRequested;   // post-insert: re-polish the last text with the CHOSEN template id

    // Templates offered by the 换模板重润色 picker (⚡auto + saved templates). Set by TrayApp before ShowInserted.
    private System.Collections.Generic.List<(string id, string name)> _repolishTemplates = new();
    public void SetRepolishTemplates(System.Collections.Generic.IEnumerable<(string id, string name)> t)
        => _repolishTemplates = new System.Collections.Generic.List<(string, string)>(t);
    /// <summary>Dev/screenshot hook: open the re-polish template menu directly.</summary>
    public void DevShowRepolishMenu() { _state = OverlayState.Inserted; ShowRepolishMenu(); }

    public string CurrentText => _text;
    public IntPtr Handle => new WindowInteropHelper(this).EnsureHandle();

    // ---- palette (self-contained; matches Styles.xaml) ----
    private static SolidColorBrush Hex(string h) => new((Color)System.Windows.Media.ColorConverter.ConvertFromString(h));
    private static readonly Brush Bg = Hex("#15151B"), AccentA = Hex("#7C5CFF"), AccentB = Hex("#38E1D6"),
        TextB = Hex("#ECECF1"), Muted = Hex("#8A8A99"), Surface2 = Hex("#1E1E26"),
        OkB = Hex("#34D399"), DangerB = Hex("#FF6B6B"), Hair = Hex("#22FFFFFF");

    public OverlayWindow()
    {
        WindowStyle = WindowStyle.None;
        AllowsTransparency = true;
        Background = Brushes.Transparent;
        ShowInTaskbar = false;
        ShowActivated = false;
        Topmost = true;
        ResizeMode = ResizeMode.NoResize;
        SizeToContent = SizeToContent.Manual;
        Width = 560; Height = 64;
        for (int i = 0; i < _bars.Length; i++) _bars[i] = 0.08;
        SourceInitialized += (_, _) => ApplyExStyles();
        _anim.Tick += (_, _) => OnAnimTick();
        // Hover-to-keep the "已插入" confirm (macOS parity): cursor on → cancel hide; cursor off → restart.
        MouseEnter += (_, _) => { if (_state == OverlayState.Inserted) _hideTimer?.Stop(); };
        MouseLeave += (_, _) => { if (_state == OverlayState.Inserted) StartHideTimer(); };
    }

    // ============================ public driving API ============================

    public void SetLevel(double level) => _level = Math.Max(0, Math.Min(1, level));

    /// <summary>How long the "已插入" confirm bar lingers after each utterance (seconds). 0 = vanish ASAP.</summary>
    public void SetStaySeconds(double seconds) => _staySeconds = Math.Max(0, seconds);

    public void SetText(string text)
    {
        if (!Dispatcher.CheckAccess()) { Dispatcher.BeginInvoke(() => SetText(text)); return; }
        _text = text ?? string.Empty;
        if (_streamText is not null) UpdateStreamText();
        if (_onCallBody is not null) UpdateOnCallBody();
    }

    public void ShowListening()
    {
        if (!Dispatcher.CheckAccess()) { Dispatcher.BeginInvoke(ShowListening); return; }
        _state = OverlayState.Listening; _text = string.Empty; _startedAt = DateTime.Now;
        Width = 560; Height = 64;
        SetClickThrough(true);
        BuildHud();
        PositionBottomCenter();
        if (!_anim.IsEnabled) _anim.Start();
        ShowNoActivate();
    }

    public void ShowInserted(bool autoHide = true, bool withUndo = false, bool withRepolish = false)
    {
        if (!Dispatcher.CheckAccess()) { Dispatcher.BeginInvoke(() => ShowInserted(autoHide, withUndo, withRepolish)); return; }
        if (_state == OverlayState.OnCall) return;
        _state = OverlayState.Inserted;
        Height = 56;
        SetClickThrough(false);   // allow MouseEnter/Leave (hover-to-keep) + clickable action pills
        var actions = new System.Collections.Generic.List<(string, bool, Action)>();
        if (withUndo) actions.Add(("↶ " + L10n.T("hud.undo"), false, () => { _hideTimer?.Stop(); UndoRequested?.Invoke(this, EventArgs.Empty); }));
        if (withRepolish) actions.Add(("✨ " + L10n.T("hud.repolish"), true, () => ShowRepolishMenu()));
        BuildConfirm(true, L10n.T("hud.insertedN", CharCount(_text)), actions.ToArray());
        PositionBottomCenter();
        ShowNoActivate();
        // With action pills, give the user time to reach them (hover keeps it indefinitely).
        if (!autoHide) return;
        StartHideTimer(actions.Count > 0 ? Math.Max(_staySeconds, 2.4) : -1);
    }

    /// <summary>换模板重润色: replace the HUD content with an in-window dark menu of templates (⚡auto +
    /// saved). Rendered INSIDE the overlay (not a separate Popup, which would orphan when the HUD hides) —
    /// picking one re-polishes the original text with THAT template (macOS dropdown parity).</summary>
    private void ShowRepolishMenu()
    {
        if (!Dispatcher.CheckAccess()) { Dispatcher.BeginInvoke(ShowRepolishMenu); return; }
        _hideTimer?.Stop();   // no auto-hide while the menu is open
        SetClickThrough(false);
        var items = new System.Collections.Generic.List<(string id, string name)>(_repolishTemplates);
        if (items.Count == 0) items.Add(("auto", "⚡ " + L10n.T("popup.template.auto")));
        var sp = new StackPanel { Margin = new Thickness(6) };
        sp.Children.Add(new TextBlock { Text = "✨ " + L10n.T("hud.repolish.pick"), Foreground = AccentA, FontSize = 12, FontWeight = FontWeights.SemiBold, Margin = new Thickness(12, 9, 12, 6) });
        foreach (var (id, name) in items)
        {
            var cid = id;
            var row = new Border { CornerRadius = new CornerRadius(8), Padding = new Thickness(12, 8, 14, 8), Margin = new Thickness(4, 0, 4, 2), Cursor = Cursors.Hand, Background = Brushes.Transparent,
                Child = new TextBlock { Text = name, Foreground = TextB, FontSize = 13 } };
            row.MouseEnter += (_, _) => row.Background = Surface2;
            row.MouseLeave += (_, _) => row.Background = Brushes.Transparent;
            row.MouseLeftButtonUp += (_, _) => RepolishRequested?.Invoke(this, cid);
            sp.Children.Add(row);
        }
        var panel = new Border { Background = Bg, BorderBrush = Hair, BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(14), Child = sp, Margin = new Thickness(20),
            HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center,
            Effect = new DropShadowEffect { BlurRadius = 18, ShadowDepth = 4, Opacity = 0.5, Color = Colors.Black } };
        Content = panel;
        SizeToContent = SizeToContent.WidthAndHeight;
        PositionBottomCenter();
        ShowNoActivate();
        StartHideTimer(8);   // fallback dismiss if the user picks nothing; hovering keeps it (MouseEnter)
    }

    /// <summary>(Re)start the auto-hide timer for the inserted confirm, using the configured stay duration.
    /// <paramref name="overrideSecs"/> &gt;= 0 forces a specific interval (e.g. longer when action pills show).</summary>
    private void StartHideTimer(double overrideSecs = -1)
    {
        _hideTimer?.Stop();
        // Floor at 0.35 s so even "Instant" shows a brief flash rather than never painting.
        double secs = overrideSecs >= 0 ? overrideSecs : Math.Max(_staySeconds, 0.35);
        _hideTimer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(secs) };
        _hideTimer.Tick += (_, _) => { _hideTimer?.Stop(); HideOverlay(); };
        _hideTimer.Start();
    }

    public void ShowRefining()
    {
        if (!Dispatcher.CheckAccess()) { Dispatcher.BeginInvoke(ShowRefining); return; }
        if (_state == OverlayState.OnCall) return;
        _state = OverlayState.Refining;
        Height = 56;
        SetClickThrough(true);
        BuildConfirm(false, L10n.T("hud.refining"));
        PositionBottomCenter();
        if (!_anim.IsEnabled) _anim.Start();
        ShowNoActivate();
    }

    public void ShowOnCall()
    {
        if (!Dispatcher.CheckAccess()) { Dispatcher.BeginInvoke(ShowOnCall); return; }
        _state = OverlayState.OnCall; _text = string.Empty; _paused = false; _startedAt = DateTime.Now;
        FixSize(340, 196);
        SetClickThrough(false);
        BuildOnCall();
        PositionTopRight();
        if (!_anim.IsEnabled) _anim.Start();
        ShowNoActivate();
    }

    public void HideOverlay()
    {
        if (!Dispatcher.CheckAccess()) { Dispatcher.BeginInvoke(HideOverlay); return; }
        if (_state == OverlayState.OnCall) return;
        _hideTimer?.Stop();
        _state = OverlayState.Hidden; _anim.Stop(); ClearRefs(); Hide();
    }

    public void LeaveOnCall()
    {
        if (!Dispatcher.CheckAccess()) { Dispatcher.BeginInvoke(LeaveOnCall); return; }
        _state = OverlayState.Hidden; _anim.Stop(); ClearRefs(); Hide();
    }

    public new void Dispose() { _anim.Stop(); Close(); }

    // ============================ builders ============================

    private void ClearRefs() { _streamText = _caret = _timerText = _onCallBody = _onCallTimer = null; _orbGlow = null; _hudGrid = null; }

    private Border Pill(double radius, Brush edge, double edgeAlpha, UIElement child) => new()
    {
        CornerRadius = new CornerRadius(radius), Background = Bg,
        BorderBrush = new SolidColorBrush(WithAlpha(((SolidColorBrush)edge).Color, (byte)(edgeAlpha * 255))),
        BorderThickness = new Thickness(1.4), Child = child,
        Effect = new DropShadowEffect { BlurRadius = 18, ShadowDepth = 0, Opacity = 0.5, Color = Colors.Black },
    };

    /// <summary>Force the window to a fixed size, reliably switching out of a prior SizeToContent=WidthAndHeight
    /// (confirm / re-polish menu) state. Re-assigning the same Width/Height is a no-op that won't resize a
    /// window left auto-sized, so we nudge by 1px first to guarantee a real change.</summary>
    private void FixSize(double w, double h)
    {
        SizeToContent = SizeToContent.Manual;
        Width = w + 1; Height = h + 1;
        Width = w; Height = h;
    }

    private void BuildHud()
    {
        ClearRefs();
        FixSize(560, 64);
        var grid = new Grid();
        _hudGrid = grid;
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });   // orb + wave (inset)
        grid.ColumnDefinitions.Add(new ColumnDefinition());                              // stream text
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });    // timer

        // left: a single clean center-weighted waveform (no orb), inset from the rounded edge.
        // Per-bar color interpolates AccentA→AccentB left→right for a smooth gradient sweep.
        var wave = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(22, 0, 4, 0), Height = 30 };
        var a = ((SolidColorBrush)AccentA).Color; var b = ((SolidColorBrush)AccentB).Color;
        int n = _bars.Length;
        for (int i = 0; i < n; i++)
        {
            double t = n > 1 ? (double)i / (n - 1) : 0;
            var col = System.Windows.Media.Color.FromArgb(255,
                (byte)(a.R + (b.R - a.R) * t), (byte)(a.G + (b.G - a.G) * t), (byte)(a.B + (b.B - a.B) * t));
            var r = new Rectangle { Width = 2.5, Height = 4, Fill = new SolidColorBrush(col), RadiusX = 1.25, RadiusY = 1.25, Margin = new Thickness(0.8, 0, 0.8, 0), VerticalAlignment = VerticalAlignment.Center };
            _barRects[i] = r; wave.Children.Add(r);
        }
        Grid.SetColumn(wave, 0); grid.Children.Add(wave);

        // streaming text + caret
        var textWrap = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(12, 0, 8, 0) };
        _streamText = new TextBlock { Foreground = TextB, FontFamily = new FontFamily("Cascadia Mono, Consolas"), FontSize = 14, VerticalAlignment = VerticalAlignment.Center, TextWrapping = TextWrapping.NoWrap };
        _caret = new TextBlock { Text = "▌", Foreground = AccentB, FontFamily = new FontFamily("Cascadia Mono, Consolas"), FontSize = 14, VerticalAlignment = VerticalAlignment.Center };
        textWrap.Children.Add(_streamText); textWrap.Children.Add(_caret);
        Grid.SetColumn(textWrap, 1); grid.Children.Add(textWrap);
        UpdateStreamText();

        // timer pill
        _timerText = new TextBlock { Text = Elapsed(), Foreground = Muted, FontFamily = new FontFamily("Cascadia Mono, Consolas"), FontSize = 12, VerticalAlignment = VerticalAlignment.Center };
        var timerPill = new Border { CornerRadius = new CornerRadius(11), Background = Surface2, Padding = new Thickness(9, 3, 9, 3), Margin = new Thickness(0, 0, 16, 0), VerticalAlignment = VerticalAlignment.Center, Child = _timerText };
        Grid.SetColumn(timerPill, 2); grid.Children.Add(timerPill);

        Content = Pill(Height / 2.0, AccentA, 0.6, grid);
    }

    private void BuildConfirm(bool done, string label, params (string text, bool filled, Action onClick)[] actions)
    {
        ClearRefs();
        var sp = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center, HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(14, 9, 14, 9) };
        // small status dot (green check when inserted; pulsing accent while refining) — no big glowing orb
        sp.Children.Add(StatusDot(done));
        sp.Children.Add(new TextBlock { Text = label, Foreground = done ? OkB : AccentA, FontSize = 13.5, FontWeight = FontWeights.SemiBold, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(9, 0, actions.Length > 0 ? 12 : 2, 0) });
        foreach (var (text, filled, onClick) in actions) sp.Children.Add(Pill2(text, filled, onClick, filled ? AccentA : null));
        // Subtle dark HUD bar (NOT a loud colored outline) + transparent margin so the drop shadow
        // can fade out instead of being clipped into a hard black edge at the window border.
        var pill = new Border
        {
            CornerRadius = new CornerRadius(13), Background = Bg, BorderBrush = Hair, BorderThickness = new Thickness(1),
            Child = sp, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(20),
            Effect = new DropShadowEffect { BlurRadius = 16, ShadowDepth = 3, Opacity = 0.45, Color = Colors.Black },
        };
        Content = pill;
        SizeToContent = SizeToContent.WidthAndHeight;   // window fits pill + shadow margin exactly
    }

    /// <summary>A small 16px status dot for the confirm bar — green check (done) or a soft accent dot (refining).</summary>
    private FrameworkElement StatusDot(bool done)
    {
        var g = new Grid { Width = 18, Height = 18, VerticalAlignment = VerticalAlignment.Center };
        var core = new Ellipse { Width = 18, Height = 18, Fill = done ? OkB : new SolidColorBrush(WithAlpha(((SolidColorBrush)AccentA).Color, 235)) };
        g.Children.Add(core);
        if (done) g.Children.Add(new TextBlock { Text = "✓", Foreground = Brushes.White, FontSize = 11, FontWeight = FontWeights.Bold, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center });
        else { _orbGlow = core; }   // let OnAnimTick pulse it while refining
        return g;
    }

    private void BuildOnCall()
    {
        ClearRefs();
        SizeToContent = SizeToContent.Manual;
        var root = new Grid { Margin = new Thickness(14, 12, 14, 12) };
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        root.RowDefinitions.Add(new RowDefinition());
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });

        // header: red dot + OnCall + timer
        var header = new Grid();
        var hl = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
        hl.Children.Add(new Ellipse { Width = 8, Height = 8, Fill = DangerB, VerticalAlignment = VerticalAlignment.Center });
        hl.Children.Add(new TextBlock { Text = "OnCall", Foreground = TextB, FontSize = 12, FontWeight = FontWeights.SemiBold, Margin = new Thickness(8, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center });
        header.Children.Add(hl);
        _onCallTimer = new TextBlock { Text = Elapsed(), Foreground = Muted, FontFamily = new FontFamily("Cascadia Mono, Consolas"), FontSize = 11, HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Center };
        header.Children.Add(_onCallTimer);
        Grid.SetRow(header, 0); root.Children.Add(header);

        // body transcript
        _onCallBody = new TextBlock { Foreground = TextB, FontFamily = new FontFamily("Cascadia Mono, Consolas"), FontSize = 13, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 10, 0, 0), VerticalAlignment = VerticalAlignment.Top };
        Grid.SetRow(_onCallBody, 1); root.Children.Add(_onCallBody);
        UpdateOnCallBody();

        // action pills
        var actions = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 8, 0, 0) };
        actions.Children.Add(Pill2(L10n.T("copy"), false, () => CopyRequested?.Invoke(this, EventArgs.Empty)));
        actions.Children.Add(Pill2(L10n.T("history.title"), false, () => ViewRequested?.Invoke(this, EventArgs.Empty)));
        actions.Children.Add(Pill2(_paused ? "▶" : "❚❚", false, () => { _paused = !_paused; PauseRequested?.Invoke(this, EventArgs.Empty); UpdateOnCallBody(); }));
        actions.Children.Add(Pill2(L10n.T("hud.stop"), true, () => StopRequested?.Invoke(this, EventArgs.Empty)));
        Grid.SetRow(actions, 2); root.Children.Add(actions);

        Content = new Border { CornerRadius = new CornerRadius(16), Background = Bg, BorderBrush = Hair, BorderThickness = new Thickness(1), Child = root,
            Effect = new DropShadowEffect { BlurRadius = 22, ShadowDepth = 2, Opacity = 0.5, Color = Colors.Black } };
    }

    private Border Pill2(string text, bool filled, Action onClick, Brush? fill = null)
    {
        var b = new Border { CornerRadius = new CornerRadius(13), Background = filled ? (fill ?? DangerB) : Surface2, BorderBrush = filled ? Brushes.Transparent : Hair, BorderThickness = new Thickness(1), Padding = new Thickness(11, 5, 11, 5), Margin = new Thickness(0, 0, 7, 0), Cursor = Cursors.Hand,
            Child = new TextBlock { Text = text, Foreground = filled ? Brushes.White : TextB, FontSize = 12, FontWeight = FontWeights.SemiBold } };
        b.MouseLeftButtonUp += (_, _) => onClick();
        return b;
    }

    private Grid Orb(double radius, bool done = false)
    {
        var g = new Grid { Width = radius * 2 + 24, Height = radius * 2 + 24 };
        _orbGlow = new Ellipse { Width = radius * 2 + 16, Height = radius * 2 + 16, Fill = new SolidColorBrush(WithAlpha(((SolidColorBrush)(done ? OkB : AccentA)).Color, 36)), HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
        g.Children.Add(_orbGlow);
        var core = new Ellipse { Width = radius * 2, Height = radius * 2, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center,
            Fill = done ? OkB : new LinearGradientBrush(((SolidColorBrush)AccentA).Color, ((SolidColorBrush)AccentB).Color, 45) };
        g.Children.Add(core);
        if (done) g.Children.Add(new TextBlock { Text = "✓", Foreground = Brushes.White, FontSize = radius, FontWeight = FontWeights.Bold, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center });
        return g;
    }

    // ============================ live updates ============================

    private void UpdateStreamText()
    {
        if (_streamText is null) return;
        _streamText.Foreground = TextB;
        if (_text.Length == 0) { _streamText.Text = L10n.T("hud.listening") + "  "; return; }
        // Long dictation: clip from the HEAD so the NEWEST words stay visible (…tail), not the start.
        _streamText.Text = ClipHead(_text, StreamMaxWidth());
    }

    /// <summary>Available px width for the stream text (the middle column minus the caret + padding).</summary>
    private double StreamMaxWidth()
    {
        double col = (_hudGrid is not null && _hudGrid.ColumnDefinitions.Count > 1) ? _hudGrid.ColumnDefinitions[1].ActualWidth : 0;
        return col > 40 ? col - 26 : 350;   // fallback before first layout (HUD is a fixed 560 wide)
    }

    /// <summary>Trim from the head with a leading "…" so the tail (newest words) fits in <paramref name="maxW"/>.</summary>
    private string ClipHead(string s, double maxW)
    {
        if (string.IsNullOrEmpty(s) || maxW <= 0) return s;
        var tf = new Typeface(_streamText!.FontFamily, FontStyles.Normal, FontWeights.Normal, FontStretches.Normal);
        double W(string t) => new FormattedText(t, System.Globalization.CultureInfo.CurrentCulture, System.Windows.FlowDirection.LeftToRight, tf, _streamText.FontSize, Brushes.White, 1.0).WidthIncludingTrailingWhitespace;
        if (W(s) <= maxW) return s;
        int lo = 1, hi = s.Length - 1, best = s.Length - 1;
        while (lo <= hi)
        {
            int mid = (lo + hi) / 2;
            if (W("…" + s.Substring(mid)) <= maxW) { best = mid; hi = mid - 1; }
            else lo = mid + 1;
        }
        return "…" + s.Substring(best);
    }

    private void UpdateOnCallBody()
    {
        if (_onCallBody is null) return;
        if (_paused) { _onCallBody.Text = "❚❚ " + L10n.Loc("已暂停", "Paused", "一時停止中", "일시 중지됨"); _onCallBody.Foreground = Muted; }
        else if (_text.Length == 0) { _onCallBody.Text = L10n.Loc("候机中,识别到说话即显示…", "Standby — speak to capture…", "待機中。話すと認識結果を表示します…", "대기 중. 말하면 인식 결과를 표시합니다…"); _onCallBody.Foreground = Muted; }
        else { _onCallBody.Text = _text; _onCallBody.Foreground = TextB; }
    }

    private void OnAnimTick()
    {
        _blinkTick++;
        bool speaking = (_state is OverlayState.Listening or OverlayState.OnCall) && !_paused;
        double mid = (_bars.Length - 1) / 2.0;
        for (int i = 0; i < _bars.Length; i++)
        {
            double c = 1 - Math.Abs(i - mid) / Math.Max(mid, 0.0001);    // 1 at center → 0 at edges
            double env = 0.35 + 0.65 * c;
            double idle = 0.14 + 0.30 * c;                               // resting shape = smooth symmetric hill
            double target = speaking
                ? Math.Max(idle, _level * env * (0.5 + _rng.NextDouble() * 0.7))
                : idle * (0.9 + _rng.NextDouble() * 0.2);                // gentle shimmer at rest (not flat dots)
            _bars[i] += (target - _bars[i]) * 0.3;
            _bars[i] = Math.Min(1, Math.Max(0.08, _bars[i]));
            if (_state == OverlayState.Listening && _barRects[i] is { } rr) rr.Height = Math.Max(3, _bars[i] * 30);
        }
        _level *= 0.85;
        if (_caret is not null) _caret.Visibility = _blinkTick % 16 < 8 ? Visibility.Visible : Visibility.Hidden;
        if (_orbGlow is not null) { double s = 1.0 + 0.5 * Math.Min(1.0, _level); _orbGlow.Opacity = 0.6 + 0.4 * Math.Min(1.0, _level); }
        if (_timerText is not null) _timerText.Text = Elapsed();
        if (_onCallTimer is not null) _onCallTimer.Text = Elapsed();
    }

    private string Elapsed() { var s = (int)(DateTime.Now - _startedAt).TotalSeconds; return $"{s / 60}:{s % 60:00}"; }
    private static int CharCount(string? s) => string.IsNullOrEmpty(s) ? 0 : s.Trim().Length;

    // ============================ positioning + window styles ============================

    public void PositionBottomCenter()
    {
        UpdateLayout();
        var wa = SystemParameters.WorkArea;
        Left = wa.Left + (wa.Width - ActualWidth) / 2;
        Top = wa.Bottom - ActualHeight - 80;
    }

    public void PositionTopRight()
    {
        var wa = SystemParameters.WorkArea;
        Left = wa.Right - Width - 24;
        Top = wa.Top + 24;
    }

    private const int GWL_EXSTYLE = -20;
    private const int WS_EX_NOACTIVATE = 0x08000000, WS_EX_TOOLWINDOW = 0x00000080, WS_EX_TRANSPARENT = 0x00000020;
    private bool _clickThrough;

    private void ApplyExStyles()
    {
        var h = new WindowInteropHelper(this).Handle;
        long ex = GetWindowLongPtr(h, GWL_EXSTYLE).ToInt64();
        ex |= WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW;
        if (_clickThrough) ex |= WS_EX_TRANSPARENT; else ex &= ~WS_EX_TRANSPARENT;
        SetWindowLongPtr(h, GWL_EXSTYLE, new IntPtr(ex));
    }

    private void SetClickThrough(bool on)
    {
        _clickThrough = on;
        if (new WindowInteropHelper(this).Handle != IntPtr.Zero) ApplyExStyles();
    }

    private void ShowNoActivate() { if (!IsVisible) Show(); }

    [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW", SetLastError = true)]
    private static extern IntPtr GetWindowLongPtr(IntPtr hWnd, int nIndex);
    [DllImport("user32.dll", EntryPoint = "SetWindowLongPtrW", SetLastError = true)]
    private static extern IntPtr SetWindowLongPtr(IntPtr hWnd, int nIndex, IntPtr dwNewLong);

    private static Color WithAlpha(Color c, byte a) => Color.FromArgb(a, c.R, c.G, c.B);
}
