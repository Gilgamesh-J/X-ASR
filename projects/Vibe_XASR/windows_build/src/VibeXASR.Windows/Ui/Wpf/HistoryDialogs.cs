using System;
using System.Collections.Generic;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using VibeXASR.Windows.Storage;
using Brush = System.Windows.Media.Brush;
using Brushes = System.Windows.Media.Brushes;
using FontFamily = System.Windows.Media.FontFamily;
using Button = System.Windows.Controls.Button;
using TextBox = System.Windows.Controls.TextBox;
using Orientation = System.Windows.Controls.Orientation;
using HorizontalAlignment = System.Windows.HorizontalAlignment;
using VerticalAlignment = System.Windows.VerticalAlignment;

namespace VibeXASR.Windows.Ui.Wpf;

/// <summary>Small self-contained palette for the history sub-dialogs (no merged styles needed).</summary>
internal static class HxPalette
{
    private static SolidColorBrush Hex(string h) => new((System.Windows.Media.Color)System.Windows.Media.ColorConverter.ConvertFromString(h));
    public static readonly Brush Bg = Hex("#15151B"), Surface2 = Hex("#1E1E26"), AccentA = Hex("#7C5CFF"),
        Text = Hex("#ECECF1"), Muted = Hex("#8A8A99"), Hair = Hex("#26FFFFFF"), AccentB = Hex("#38E1D6");
}

/// <summary>Single-line text prompt (tag name). Returns <see cref="Result"/> on OK.</summary>
internal sealed class HistoryPromptWindow : Window
{
    private readonly TextBox _box;
    public string Result => _box.Text;

    public HistoryPromptWindow(string label)
    {
        Title = "Vibe XASR"; Width = 340; Height = 150; ResizeMode = ResizeMode.NoResize;
        WindowStartupLocation = WindowStartupLocation.CenterOwner; Background = HxPalette.Bg;
        var sp = new StackPanel { Margin = new Thickness(16) };
        sp.Children.Add(new TextBlock { Text = label, Foreground = HxPalette.Text, FontSize = 13, Margin = new Thickness(0, 0, 0, 8) });
        _box = new TextBox { Background = HxPalette.Surface2, Foreground = HxPalette.Text, BorderBrush = HxPalette.Hair, BorderThickness = new Thickness(1), Padding = new Thickness(8, 6, 8, 6), FontSize = 13, CaretBrush = HxPalette.AccentB };
        sp.Children.Add(_box);
        var btns = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 14, 0, 0) };
        var ok = new Button { Content = "OK", Width = 76, Height = 30, Margin = new Thickness(8, 0, 0, 0), IsDefault = true };
        ok.Click += (_, _) => { DialogResult = true; };
        var cancel = new Button { Content = "Cancel", Width = 76, Height = 30, IsCancel = true };
        btns.Children.Add(cancel); btns.Children.Add(ok);
        sp.Children.Add(btns);
        Content = sp;
        Loaded += (_, _) => _box.Focus();
    }
}

/// <summary>Modal editor for one record: text + optional note title + comma-separated tags.</summary>
internal sealed class HistoryEditWindow : Window
{
    private readonly TextBox _text, _title, _tags;
    public string ResultText => _text.Text;
    public string? ResultTitle => string.IsNullOrWhiteSpace(_title.Text) ? null : _title.Text.Trim();
    public List<string> ResultTags => _tags.Text.Split(new[] { ',', '，' }, StringSplitOptions.RemoveEmptyEntries).Select(s => s.Trim()).Where(s => s.Length > 0).Distinct().ToList();

    public HistoryEditWindow(HistoryEntry e, bool zh)
    {
        Title = L10n.Loc("编辑记录", "Edit record", "記録を編集", "기록 편집"); Width = 460; Height = 380; ResizeMode = ResizeMode.NoResize;
        WindowStartupLocation = WindowStartupLocation.CenterOwner; Background = HxPalette.Bg;
        var sp = new StackPanel { Margin = new Thickness(16) };
        sp.Children.Add(Lbl(L10n.Loc("文字", "Text", "テキスト", "텍스트")));
        _text = Field(e.Text.Replace("\r\n", "\n"), 150, true);
        sp.Children.Add(_text);
        sp.Children.Add(Lbl(L10n.Loc("笔记标题(可选)", "Note title (optional)", "メモのタイトル(任意)", "메모 제목(선택)")));
        _title = Field(e.Title ?? "", 0, false); sp.Children.Add(_title);
        sp.Children.Add(Lbl(L10n.Loc("标签(逗号分隔)", "Tags (comma-separated)", "タグ(カンマ区切り)", "태그(쉼표로 구분)")));
        _tags = Field(string.Join(", ", e.Tags), 0, false); sp.Children.Add(_tags);
        var btns = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 14, 0, 0) };
        var cancel = new Button { Content = L10n.Loc("取消", "Cancel", "キャンセル", "취소"), Width = 84, Height = 30, Margin = new Thickness(0, 0, 8, 0), IsCancel = true };
        var ok = new Button { Content = L10n.Loc("保存", "Save", "保存", "저장"), Width = 84, Height = 30, IsDefault = true };
        ok.Click += (_, _) => { DialogResult = true; };
        btns.Children.Add(cancel); btns.Children.Add(ok);
        sp.Children.Add(btns);
        Content = sp;
    }

    private static TextBlock Lbl(string t) => new() { Text = t, Foreground = HxPalette.Muted, FontSize = 11.5, Margin = new Thickness(2, 10, 0, 4) };
    private static TextBox Field(string text, double height, bool multiline) => new()
    {
        Text = text, AcceptsReturn = multiline, TextWrapping = multiline ? TextWrapping.Wrap : TextWrapping.NoWrap,
        Height = height > 0 ? height : double.NaN, VerticalContentAlignment = multiline ? VerticalAlignment.Top : VerticalAlignment.Center,
        VerticalScrollBarVisibility = multiline ? ScrollBarVisibility.Auto : ScrollBarVisibility.Disabled,
        Background = HxPalette.Surface2, Foreground = HxPalette.Text, BorderBrush = HxPalette.Hair, BorderThickness = new Thickness(1),
        Padding = new Thickness(8, 6, 8, 6), FontFamily = new FontFamily(multiline ? "Cascadia Mono, Consolas" : "Segoe UI"), FontSize = 13, CaretBrush = HxPalette.AccentB,
    };
}
