using System;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Shapes;
using VibeXASR.Windows.Dictation;
using VibeXASR.Windows.Storage;
using Brush = System.Windows.Media.Brush;
using FontFamily = System.Windows.Media.FontFamily;
using Orientation = System.Windows.Controls.Orientation;
using HorizontalAlignment = System.Windows.HorizontalAlignment;
using VerticalAlignment = System.Windows.VerticalAlignment;
using Cursors = System.Windows.Input.Cursors;
using Ellipse = System.Windows.Shapes.Ellipse;
using Point = System.Windows.Point;

namespace VibeXASR.Windows.Ui.Wpf;

/// <summary>The macOS-style menu-bar dropdown (WPF): a status row (pulsing dot + state),
/// the most-recent card, an "Enable dictation" toggle, and Settings / History / Quit entries.
/// Borderless rounded popup anchored above the tray; closes when it loses focus.</summary>
public partial class TrayPopupWindow : Window
{
    private readonly IAppController _app;
    private Settings S => _app.Settings;
    private static bool Zh => L10n.Resolved == Lang.Zh;

    public TrayPopupWindow(IAppController app)
    {
        _app = app;
        InitializeComponent();
        Deactivated += (_, _) => { if (Environment.GetEnvironmentVariable("VIBEXASR_OPEN") != "popup") Hide(); };
        Loaded += (_, _) => SelfCapture();
    }

    /// <summary>Position above the notification area and show (activated, so it self-closes).</summary>
    public void ShowNear()
    {
        Rebuild();
        Show();
        UpdateLayout();
        var wa = SystemParameters.WorkArea;
        Left = wa.Right - ActualWidth - 4;
        Top = wa.Bottom - ActualHeight - 4;
        Activate();
    }

    /// <summary>Show near a screen point (the launcher's top-right) — its bottom-right corner anchors
    /// to the point, then clamps to the work area. Used by the desktop launcher.</summary>
    public void ShowAt(double screenX, double screenY)
    {
        Rebuild();
        Show();
        UpdateLayout();
        var wa = SystemParameters.WorkArea;
        double left = screenX - ActualWidth;          // popup sits to the LEFT of the anchor
        double top = screenY - ActualHeight - 6;      // and ABOVE it
        Left = Math.Max(wa.Left + 4, Math.Min(left, wa.Right - ActualWidth - 4));
        Top = Math.Max(wa.Top + 4, Math.Min(top, wa.Bottom - ActualHeight - 4));
        Activate();
    }

    /// <summary>Refresh dynamic state (listening dot, recent text, enable toggle). Cheap re-layout.</summary>
    public void Invalidate() { if (IsVisible) Rebuild(); }

    private void Rebuild()
    {
        Root.Children.Clear();
        bool listening = _app.IsListening;
        bool ready = _app.EngineReady;

        // ---- status row: pulsing dot + state + sub ----
        var statusGrid = new Grid { Margin = new Thickness(20, 2, 16, 0) };
        statusGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        statusGrid.ColumnDefinitions.Add(new ColumnDefinition());

        var dotHost = new Grid { Width = 22, Height = 22, VerticalAlignment = VerticalAlignment.Center };
        Brush dotColor = !ready ? Br("Warn") : listening ? Br("AccentA") : Br("Success");
        if (listening)
        {
            var ring = new Ellipse { Width = 9, Height = 9, Fill = Br("AccentA"), HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center, RenderTransformOrigin = new Point(0.5, 0.5) };
            var st = new ScaleTransform(1, 1); ring.RenderTransform = st;
            var grow = new DoubleAnimation(1, 2.6, TimeSpan.FromSeconds(1.1)) { RepeatBehavior = RepeatBehavior.Forever };
            var fade = new DoubleAnimation(0.5, 0, TimeSpan.FromSeconds(1.1)) { RepeatBehavior = RepeatBehavior.Forever };
            st.BeginAnimation(ScaleTransform.ScaleXProperty, grow);
            st.BeginAnimation(ScaleTransform.ScaleYProperty, grow);
            ring.BeginAnimation(OpacityProperty, fade);
            dotHost.Children.Add(ring);
        }
        dotHost.Children.Add(new Ellipse { Width = 9, Height = 9, Fill = dotColor, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center });
        Grid.SetColumn(dotHost, 0); statusGrid.Children.Add(dotHost);

        var stateStack = new StackPanel { Margin = new Thickness(10, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center };
        string state = !ready ? L10n.T("menu.loading") : listening ? L10n.T("menu.listening") : L10n.T("menu.ready");
        stateStack.Children.Add(new TextBlock { Text = state, Foreground = Br("Text"), FontSize = 13.5, FontWeight = FontWeights.SemiBold });
        stateStack.Children.Add(new TextBlock { Text = "X-ASR · " + (Zh ? "本地" : "local"), Foreground = Br("TextMuted"), FontSize = 10.5, FontFamily = new FontFamily("Cascadia Mono, Consolas") });
        Grid.SetColumn(stateStack, 1); statusGrid.Children.Add(stateStack);
        Root.Children.Add(statusGrid);

        AddSeparator();

        // ---- most recent card ----
        Root.Children.Add(new TextBlock { Text = L10n.T("menu.recent"), Foreground = Br("TextMuted"), FontSize = 10, FontFamily = new FontFamily("Cascadia Mono, Consolas"), Margin = new Thickness(16, 10, 16, 6) });
        string recent = listening ? _app.CurrentOverlayText : (_app.History?.List().FirstOrDefault()?.Text ?? "");
        bool empty = string.IsNullOrEmpty(recent);
        var card = new Border { CornerRadius = new CornerRadius(9), Background = Br("Surface2"), BorderBrush = Br("Hairline"), BorderThickness = new Thickness(1), Margin = new Thickness(16, 0, 16, 4), Padding = new Thickness(12, 10, 12, 10), MinHeight = 36 };
        card.Child = new TextBlock { Text = empty ? (Zh ? "(暂无)" : "(none)") : recent, Foreground = Br(empty ? "TextMuted" : "Text"), FontFamily = new FontFamily("Cascadia Mono, Consolas"), FontSize = 12, TextWrapping = TextWrapping.Wrap, MaxHeight = 120 };
        Root.Children.Add(card);

        AddSeparator();

        // ---- enable toggle row ----
        var enableGrid = new Grid { Margin = new Thickness(16, 8, 16, 8) };
        enableGrid.ColumnDefinitions.Add(new ColumnDefinition());
        enableGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        enableGrid.Children.Add(new TextBlock { Text = L10n.T("menu.enable"), Foreground = Br("Text"), FontSize = 13, VerticalAlignment = VerticalAlignment.Center });
        var toggle = new System.Windows.Controls.Primitives.ToggleButton { Style = St("Toggle"), IsChecked = _app.DictationEnabled, HorizontalAlignment = HorizontalAlignment.Right };
        toggle.Checked += (_, _) => _app.DictationEnabled = true;
        toggle.Unchecked += (_, _) => _app.DictationEnabled = false;
        Grid.SetColumn(toggle, 1); enableGrid.Children.Add(toggle);
        Root.Children.Add(enableGrid);

        // ---- AI polish toggle (云端润色; enabling forces 说完插入 mode) ----
        var polishGrid = new Grid { Margin = new Thickness(16, 0, 16, 8) };
        polishGrid.ColumnDefinitions.Add(new ColumnDefinition());
        polishGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var polishLabel = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
        polishLabel.Children.Add(new TextBlock { Text = "✨ " + L10n.T("tab.cloud"), Foreground = Br("Text"), FontSize = 13, VerticalAlignment = VerticalAlignment.Center });
        polishGrid.Children.Add(polishLabel);
        var polish = new System.Windows.Controls.Primitives.ToggleButton { Style = St("Toggle"), IsChecked = S.CloudEnabled, HorizontalAlignment = HorizontalAlignment.Right };
        polish.Checked += (_, _) => { S.CloudEnabled = true; _app.SetMode(DictationMode.Paste); _app.ApplyCloudSettings(); };
        polish.Unchecked += (_, _) => { S.CloudEnabled = false; _app.ApplyCloudSettings(); };
        Grid.SetColumn(polish, 1); polishGrid.Children.Add(polish);
        Root.Children.Add(polishGrid);

        AddSeparator();

        // ---- entries ----
        Root.Children.Add(MenuEntry("⚙", L10n.T("menu.settings"), false, () => { Hide(); _app.OpenSettings(); }));
        Root.Children.Add(MenuEntry("🗂", L10n.T("menu.history"), false, () => { Hide(); _app.OpenHistory(); }));
        Root.Children.Add(MenuEntry("⏻", L10n.T("menu.quit"), true, () => _app.Quit()));
    }

    private void AddSeparator() => Root.Children.Add(new Border { Height = 1, Background = Br("Hairline"), Margin = new Thickness(12, 8, 12, 8) });

    private Border MenuEntry(string icon, string text, bool destructive, Action onClick)
    {
        var sp = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
        var fg = destructive ? Br("Danger") : Br("Text");
        sp.Children.Add(new TextBlock { Text = icon, FontSize = 14, Foreground = fg, Width = 26, TextAlignment = TextAlignment.Center, VerticalAlignment = VerticalAlignment.Center });
        sp.Children.Add(new TextBlock { Text = text, FontSize = 13, Foreground = fg, Margin = new Thickness(8, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center });
        var row = new Border { CornerRadius = new CornerRadius(8), Padding = new Thickness(10, 8, 10, 8), Margin = new Thickness(6, 1, 6, 1), Cursor = Cursors.Hand, Background = System.Windows.Media.Brushes.Transparent, Child = sp };
        row.MouseEnter += (_, _) => row.Background = destructive ? Br("Danger25") : Br("AccentSoft");
        row.MouseLeave += (_, _) => row.Background = System.Windows.Media.Brushes.Transparent;
        row.MouseLeftButtonUp += (_, _) => onClick();
        return row;
    }

    private Style St(string key) => (Style)FindResource(key);
    private Brush Br(string key)
    {
        if (key == "Danger25") return new SolidColorBrush(System.Windows.Media.Color.FromArgb(41, 0xFF, 0x6B, 0x6B));
        return (Brush)FindResource(key);
    }

    private void SelfCapture()
    {
        var shot = Environment.GetEnvironmentVariable("VIBEXASR_SHOT");
        if (string.IsNullOrEmpty(shot)) return;
        Dispatcher.BeginInvoke(System.Windows.Threading.DispatcherPriority.Loaded, new Action(() =>
        {
            try
            {
                int w = (int)Math.Ceiling(ActualWidth), h = (int)Math.Ceiling(ActualHeight);
                var rtb = new System.Windows.Media.Imaging.RenderTargetBitmap(w, h, 96, 96, PixelFormats.Pbgra32);
                rtb.Render(this);
                var enc = new System.Windows.Media.Imaging.PngBitmapEncoder();
                enc.Frames.Add(System.Windows.Media.Imaging.BitmapFrame.Create(rtb));
                using var fs = System.IO.File.Create(shot); enc.Save(fs);
            }
            catch { }
            if (System.Windows.Application.Current is { } a) a.Shutdown(); else Close();
        }));
    }
}
