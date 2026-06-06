using System;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Shapes;
using System.Windows.Threading;
using VibeXASR.Windows.Storage;
// Disambiguate WPF vs WinForms/Drawing.
using Brush = System.Windows.Media.Brush;
using Brushes = System.Windows.Media.Brushes;
using FontFamily = System.Windows.Media.FontFamily;
using Button = System.Windows.Controls.Button;
using TextBox = System.Windows.Controls.TextBox;
using Orientation = System.Windows.Controls.Orientation;
using HorizontalAlignment = System.Windows.HorizontalAlignment;
using VerticalAlignment = System.Windows.VerticalAlignment;
using Cursors = System.Windows.Input.Cursors;
using MessageBox = System.Windows.MessageBox;
using Rectangle = System.Windows.Shapes.Rectangle;
using Clipboard = System.Windows.Clipboard;
using Path = System.IO.Path;

namespace VibeXASR.Windows.Ui.Wpf;

/// <summary>The redesigned History window (WPF). Mirrors the WinForms HistoryPanel: header
/// (logo + count + Export / Clear), privacy banner, cumulative stats, and a newest-first list
/// with per-row Copy / Edit / Delete revealed on hover + inline editing.</summary>
public partial class HistoryWindow : Window
{
    private readonly HistoryStore _store;
    private readonly DispatcherTimer _tick = new() { Interval = TimeSpan.FromSeconds(1) };
    private static bool Zh => L10n.Resolved == Lang.Zh;

    public HistoryWindow(HistoryStore store)
    {
        _store = store;
        InitializeComponent();
        SourceInitialized += (_, _) => DarkTitleBar();
        ExportBtn.Content = L10n.T("history.export");
        ClearBtn.Content = L10n.T("clear.all");
        ClearBtn.Foreground = Br("Danger");
        ExportBtn.Click += (_, _) => ExportVisible();
        ClearBtn.Click += (_, _) => ConfirmClear();
        Reload();
        _tick.Tick += (_, _) => RefreshExpiry();
        _tick.Start();
        Closed += (_, _) => _tick.Stop();
        Loaded += (_, _) => SelfCapture();
    }

    private void Reload()
    {
        var items = _store.List();
        TitleText.Text = L10n.T("history.title");
        CountText.Text = L10n.T("history.count", items.Count);
        PrivacyTitle.Text = Zh ? "您的数据永远保存在本地,绝不上云" : "Your data stays on this device";
        PrivacySub.Text = L10n.T("history.privacy");
        ExportBtn.Visibility = ClearBtn.Visibility = items.Count > 0 ? Visibility.Visible : Visibility.Collapsed;

        long chars = _store.LifetimeChars;
        StatsBar.Visibility = chars > 0 ? Visibility.Visible : Visibility.Collapsed;
        if (chars > 0) StatsText.Text = "📊  " + StatsLine(chars);

        List.Children.Clear();
        if (items.Count == 0)
        {
            List.Children.Add(new TextBlock
            {
                Text = "🗒\n\n" + L10n.T("history.empty"), Foreground = Br("TextMuted"), FontSize = 13,
                TextAlignment = TextAlignment.Center, HorizontalAlignment = HorizontalAlignment.Center,
                Margin = new Thickness(0, 80, 0, 0),
            });
            return;
        }
        foreach (var e in items) List.Children.Add(BuildRow(e));
    }

    private Border BuildRow(HistoryEntry entry)
    {
        var grid = new Grid { Margin = new Thickness(14, 11, 12, 11) };
        grid.ColumnDefinitions.Add(new ColumnDefinition());
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        var left = new StackPanel();
        var body = new TextBlock { Text = entry.Text, Foreground = Br("Text"), FontFamily = new FontFamily("Cascadia Mono, Consolas"), FontSize = 13, TextWrapping = TextWrapping.Wrap, LineHeight = 19 };
        left.Children.Add(body);

        // meta line
        var meta = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 6, 0, 0) };
        meta.Children.Add(new TextBlock { Text = entry.Timestamp.LocalDateTime.ToString("g", CultureInfo.CurrentCulture), Foreground = Br("TextMuted"), FontFamily = new FontFamily("Cascadia Mono, Consolas"), FontSize = 10.5 });
        if (entry.ExpiresAt is { } exp)
        {
            int remain = Math.Max(0, (int)Math.Ceiling((exp - DateTimeOffset.Now).TotalSeconds));
            meta.Children.Add(new TextBlock { Text = $"  ⏳ {remain}s", Foreground = Br("Danger"), FontFamily = new FontFamily("Cascadia Mono, Consolas"), FontSize = 10.5, Tag = "expiry" });
        }
        if (entry.Mode == "oncall")
            meta.Children.Add(new Border { Style = St("Badge"), Margin = new Thickness(8, 0, 0, 0), Child = new TextBlock { Text = "OnCall", Foreground = Br("AccentB"), FontSize = 10, FontWeight = FontWeights.SemiBold } });
        left.Children.Add(meta);
        Grid.SetColumn(left, 0); grid.Children.Add(left);

        // hover actions
        var actions = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Top, Visibility = Visibility.Hidden };
        var copy = IconBtn("⧉", false); var edit = IconBtn("✎", false); var del = IconBtn("🗑", true);
        actions.Children.Add(copy); actions.Children.Add(edit); actions.Children.Add(del);
        Grid.SetColumn(actions, 1); grid.Children.Add(actions);

        var card = new Border { Style = St("Card"), Margin = new Thickness(0, 0, 0, 8), Child = grid };
        card.MouseEnter += (_, _) => { if (body.Visibility == Visibility.Visible) actions.Visibility = Visibility.Visible; };
        card.MouseLeave += (_, _) => actions.Visibility = Visibility.Hidden;

        copy.Click += (_, _) => { try { Clipboard.SetText(entry.Text); } catch { } };
        del.Click += (_, _) => { _store.Delete(entry.Id); Reload(); };
        edit.Click += (_, _) =>
        {
            var editor = new TextBox { Style = St("FieldBox"), Text = entry.Text, AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, FontFamily = new FontFamily("Cascadia Mono, Consolas"), FontSize = 13, MinHeight = 60, VerticalContentAlignment = VerticalAlignment.Top };
            body.Visibility = Visibility.Collapsed; actions.Visibility = Visibility.Hidden;
            left.Children.Insert(0, editor);
            editor.Focus(); editor.CaretIndex = editor.Text.Length;
            void Commit() { var t = editor.Text.Trim(); if (!string.IsNullOrEmpty(t)) _store.Update(entry.Id, t); Reload(); }
            editor.KeyDown += (_, ev) =>
            {
                if (ev.Key == Key.Enter && (Keyboard.Modifiers & ModifierKeys.Shift) == 0) { ev.Handled = true; Commit(); }
                else if (ev.Key == Key.Escape) { Reload(); }
            };
            editor.LostKeyboardFocus += (_, _) => Commit();
        };
        return card;
    }

    private Button IconBtn(string glyph, bool danger)
    {
        var b = new Button { Style = St("Ghost"), Content = glyph, MinWidth = 0, Width = 30, Height = 28, Padding = new Thickness(0), Margin = new Thickness(2, 0, 0, 0), Cursor = Cursors.Hand };
        if (danger) b.Foreground = Br("Danger");
        return b;
    }

    private void RefreshExpiry()
    {
        bool changed = _store.List().Count != List.Children.OfType<Border>().Count();
        if (changed) { Reload(); return; }
        // live-update countdown text without a full rebuild
        foreach (var card in List.Children.OfType<Border>())
            if (card.Child is Grid g && g.Children[0] is StackPanel left && left.Children.OfType<StackPanel>().FirstOrDefault() is { } meta)
                foreach (var tb in meta.Children.OfType<TextBlock>())
                    if (tb.Tag as string == "expiry") { /* recomputed on next full reload */ }
    }

    private string StatsLine(long chars)
    {
        double minutes = chars / 200.0, hours = minutes / 60.0;
        if (chars > 10_000 && hours > 100) return L10n.T("history.stats.big");
        string a = L10n.T("history.stats.chars", chars.ToString("N0", CultureInfo.CurrentCulture));
        string b = hours >= 1 ? L10n.T("history.stats.hours", hours.ToString("0.0"))
                              : L10n.T("history.stats.minutes", minutes < 1 ? "<1" : ((int)minutes).ToString());
        return a + b;
    }

    private void ConfirmClear()
    {
        if (MessageBox.Show(L10n.T("history.clear.confirm.body"), L10n.T("history.clear.confirm.title"),
                MessageBoxButton.OKCancel, MessageBoxImage.Warning) == MessageBoxResult.OK)
        { _store.ClearAll(); Reload(); }
    }

    private void ExportVisible()
    {
        var dlg = new Microsoft.Win32.SaveFileDialog { Title = L10n.T("history.export.panel"), FileName = "vibe-xasr-history.json", Filter = "JSON (*.json)|*.json|Text (*.txt)|*.txt" };
        if (dlg.ShowDialog(this) != true) return;
        var items = _store.List();
        bool isText = Path.GetExtension(dlg.FileName).Equals(".txt", StringComparison.OrdinalIgnoreCase);
        try
        {
            if (isText)
            {
                var sb = new StringBuilder();
                foreach (var e in items) sb.Append(e.Timestamp.LocalDateTime.ToString("g", CultureInfo.CurrentCulture)).Append('\n').Append(e.Text).Append("\n\n");
                File.WriteAllText(dlg.FileName, sb.ToString());
            }
            else
            {
                var arr = items.Select(e => new { date = e.Timestamp.ToString("o"), text = e.Text, mode = e.Mode });
                File.WriteAllText(dlg.FileName, JsonSerializer.Serialize(arr, new JsonSerializerOptions { WriteIndented = true }));
            }
        }
        catch (Exception ex) { MessageBox.Show(ex.Message); }
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
