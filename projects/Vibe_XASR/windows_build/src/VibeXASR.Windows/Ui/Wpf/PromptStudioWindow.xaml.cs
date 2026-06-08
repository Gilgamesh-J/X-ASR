using System;
using System.Collections.Generic;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using VibeXASR.Windows.Refine;
using VibeXASR.Windows.Storage;
using Brush = System.Windows.Media.Brush;
using Brushes = System.Windows.Media.Brushes;
using FontFamily = System.Windows.Media.FontFamily;
using Button = System.Windows.Controls.Button;
using TextBox = System.Windows.Controls.TextBox;
using Orientation = System.Windows.Controls.Orientation;
using HorizontalAlignment = System.Windows.HorizontalAlignment;
using VerticalAlignment = System.Windows.VerticalAlignment;
using Cursors = System.Windows.Input.Cursors;
using Clipboard = System.Windows.Clipboard;

namespace VibeXASR.Windows.Ui.Wpf;

/// <summary>提示词工作室 — a standalone Prompt Template Studio window (macOS build 204 parity).
/// Self-contained (own palette, no merged styles) so it can be opened independently from the tray or
/// the AI 润色 tab. Reads/writes the same <c>Settings.Cloud*</c> truth source via <see cref="IAppController"/>.</summary>
public sealed class PromptStudioWindow : Window
{
    private readonly IAppController _app;
    private Settings S => _app.Settings;
    private static bool Zh => L10n.Resolved is Lang.Zh or Lang.Hant;

    private List<CloudTemplate> _templates = new();
    private string _copiedId = "";   // briefly-highlighted "copied" chip
    private readonly StackPanel _root = new() { Margin = new Thickness(20) };

    private static SolidColorBrush Hex(string h) => new((System.Windows.Media.Color)System.Windows.Media.ColorConverter.ConvertFromString(h));
    private static readonly Brush Bg = Hex("#15151B"), Surface = Hex("#1A1A22"), Surface2 = Hex("#1E1E26"),
        AccentA = Hex("#7C5CFF"), AccentSoft = Hex("#262036"), AccentB = Hex("#38E1D6"),
        TextB = Hex("#ECECF1"), Muted = Hex("#8A8A99"), Hair = Hex("#26FFFFFF"), Ok = Hex("#34D399"), Danger = Hex("#FF6B6B");

    public PromptStudioWindow(IAppController app)
    {
        _app = app;
        Title = L10n.T("studio.window");
        Width = 580; Height = 600; MinWidth = 460; MinHeight = 420;
        Background = Bg; WindowStartupLocation = WindowStartupLocation.CenterScreen;
        var scroll = new ScrollViewer { VerticalScrollBarVisibility = ScrollBarVisibility.Auto, Content = _root };
        Content = scroll;
        SourceInitialized += (_, _) => DarkTitleBar();
        Rebuild();
    }

    private void Rebuild()
    {
        _templates = CloudJson.Templates(S.CloudTemplatesJson);
        if (S.CloudActiveTemplate != "auto" && _templates.All(t => t.Id != S.CloudActiveTemplate))
        { S.CloudActiveTemplate = "auto"; S.Save(); }

        _root.Children.Clear();
        _root.Children.Add(new TextBlock { Text = L10n.Loc("提示词模板", "Prompt templates", "プロンプトテンプレート", "프롬프트 템플릿"), Foreground = TextB, FontSize = 17, FontWeight = FontWeights.Bold, Margin = new Thickness(0, 0, 0, 4) });
        _root.Children.Add(new TextBlock { Text = L10n.Loc("「自动」由处理项实时拼成;模板可增删改,点选即套用。一键复制可分享给他人。", "“Auto” is built from the toggles. Templates can be added/edited; click to activate. Copy to share.", "「自動」は処理項目からリアルタイムで生成されます。テンプレートは追加・編集でき、選択すると適用されます。ワンタップでコピーして共有できます。", "'자동'은 처리 항목에서 실시간으로 생성됩니다. 템플릿은 추가·편집할 수 있으며 선택하면 적용됩니다. 원터치 복사로 공유할 수 있습니다."), Foreground = Muted, FontSize = 12, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 0, 0, 14) });

        // chips
        var chips = new WrapPanel();
        chips.Children.Add(Chip("⚡ " + L10n.Loc("自动", "Auto", "自動", "자동"), "auto", S.CloudActiveTemplate == "auto", null));
        foreach (var t in _templates)
        {
            var tid = t.Id;
            chips.Children.Add(Chip(t.Name, tid, S.CloudActiveTemplate == tid,
                () => { _templates.RemoveAll(x => x.Id == tid); if (S.CloudActiveTemplate == tid) S.CloudActiveTemplate = "auto"; Commit(); }));
        }
        var add = new Border { CornerRadius = new CornerRadius(8), BorderBrush = Hair, BorderThickness = new Thickness(1), Padding = new Thickness(11, 6, 11, 6), Margin = new Thickness(0, 0, 8, 8), Cursor = Cursors.Hand, Child = new TextBlock { Text = L10n.Loc("＋ 新建模板", "＋ New", "＋ 新規テンプレート", "＋ 새 템플릿"), Foreground = AccentA, FontSize = 12 } };
        add.MouseLeftButtonUp += (_, _) =>
        {
            int n = _templates.Count + 1; var id = $"t{n}-{_templates.Count}";
            _templates.Add(new CloudTemplate { Id = id, Name = L10n.Loc("模板", "Tpl", "テンプレート", "템플릿") + n, Content = CurrentPrompt() });
            S.CloudActiveTemplate = id; Commit();
        };
        chips.Children.Add(add);
        _root.Children.Add(chips);

        // editor (declared first so token chips can target it)
        bool isAuto = S.CloudActiveTemplate == "auto";
        var editor = new TextBox { Text = CurrentPrompt(), AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, Height = 300,
            VerticalContentAlignment = VerticalAlignment.Top, VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            FontFamily = new FontFamily("Cascadia Mono, Consolas"), FontSize = 12.5, Background = Surface2, Foreground = TextB,
            BorderBrush = Hair, BorderThickness = new Thickness(1), Padding = new Thickness(10), Margin = new Thickness(0, 6, 0, 0),
            CaretBrush = AccentB };
        editor.LostFocus += (_, _) =>
        {
            var v = editor.Text;
            if (S.CloudActiveTemplate == "auto") S.CloudAutoOverride = v;
            else { var t = _templates.FirstOrDefault(x => x.Id == S.CloudActiveTemplate); if (t is not null) t.Content = v; }
            Commit(rebuild: false);
        };

        // token toolbar
        var tokRow = new WrapPanel { Margin = new Thickness(0, 10, 0, 2) };
        tokRow.Children.Add(new TextBlock { Text = L10n.Loc("插入占位符", "Insert token", "プレースホルダーを挿入", "자리표시자 삽입"), Foreground = Muted, FontSize = 12, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 10, 0) });
        foreach (var (token, _) in CloudSeeds.Tokens)
        {
            var tok = token;
            var chip = new Border { CornerRadius = new CornerRadius(6), Background = AccentSoft, Padding = new Thickness(8, 3, 8, 3), Margin = new Thickness(0, 0, 8, 6), Cursor = Cursors.Hand, Child = new TextBlock { Text = token, Foreground = AccentA, FontFamily = new FontFamily("Cascadia Mono, Consolas"), FontSize = 11 } };
            chip.MouseLeftButtonUp += (_, _) => { int p = Math.Max(0, editor.SelectionStart); editor.Text = editor.Text.Insert(p, tok); editor.SelectionStart = p + tok.Length; editor.Focus(); };
            tokRow.Children.Add(chip);
        }
        _root.Children.Add(tokRow);
        _root.Children.Add(editor);

        // action row: copy active prompt
        var actions = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 12, 0, 0) };
        var copyBtn = new Border { CornerRadius = new CornerRadius(8), Background = AccentSoft, Padding = new Thickness(14, 7, 14, 7), Cursor = Cursors.Hand,
            Child = new TextBlock { Text = (_copiedId == S.CloudActiveTemplate ? "✓ " + L10n.Loc("已复制", "Copied", "コピーしました", "복사됨") : "⧉ " + L10n.Loc("复制当前提示词", "Copy prompt", "現在のプロンプトをコピー", "현재 프롬프트 복사")), Foreground = _copiedId == S.CloudActiveTemplate ? Ok : AccentA, FontSize = 12.5, FontWeight = FontWeights.SemiBold } };
        copyBtn.MouseLeftButtonUp += (_, _) => { try { Clipboard.SetText(editor.Text); } catch { } _copiedId = S.CloudActiveTemplate; Rebuild(); };
        actions.Children.Add(copyBtn);
        _root.Children.Add(actions);

        // per-template hotkey (hold-to-talk triggers this template). 「自动」not bindable.
        if (!isAuto)
        {
            var (vk, mods) = CloudTemplateHotkeys.For(S.CloudTemplateHotkeysJson, S.CloudActiveTemplate);
            var hk = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 14, 0, 0), VerticalAlignment = VerticalAlignment.Center };
            hk.Children.Add(new TextBlock { Text = L10n.T("tpl.hotkey"), Foreground = Muted, FontSize = 12, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 10, 0) });
            hk.Children.Add(HotkeyRecorder(S.CloudActiveTemplate, vk, mods));
            if (vk != 0)
            {
                var clear = new TextBlock { Text = L10n.T("tpl.hotkey.clear"), Foreground = Muted, FontSize = 11.5, Margin = new Thickness(10, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center, Cursor = Cursors.Hand };
                clear.MouseLeftButtonUp += (_, _) => { S.CloudTemplateHotkeysJson = CloudTemplateHotkeys.Set(S.CloudTemplateHotkeysJson, S.CloudActiveTemplate, 0, 0); _app.ApplyCloudSettings(); Rebuild(); };
                hk.Children.Add(clear);
            }
            _root.Children.Add(hk);
            _root.Children.Add(new TextBlock { Text = L10n.T("tpl.hotkey.hint"), Foreground = Muted, FontSize = 10.5, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 6, 0, 0) });
        }

        _root.Children.Add(new TextBlock { Text = isAuto ? L10n.Loc("「自动」可编辑为自定义起始词;清空则恢复实时拼装。", "Edit “Auto” to override; clear to restore the live-built prompt.", "「自動」を編集してカスタムの起点にできます。空にするとリアルタイム生成に戻ります。", "'자동'을 편집해 사용자 지정 시작 문구로 만들 수 있습니다. 비우면 실시간 생성으로 돌아갑니다.") : "",
            Foreground = Muted, FontSize = 11, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 10, 0, 0) });
    }

    private VibeXASR.Windows.Ui.KeyCaptureHook? _tplHook;
    private Border HotkeyRecorder(string templateId, int vk, int mods)
    {
        var label = new TextBlock { Text = vk != 0 ? VibeXASR.Windows.Ui.VkNames.Combo(vk, mods) : L10n.T("tpl.hotkey.unset"), Foreground = vk != 0 ? TextB : Muted, FontSize = 12.5, FontWeight = FontWeights.SemiBold };
        var box = new Border { CornerRadius = new CornerRadius(7), Background = Surface2, BorderBrush = Hair, BorderThickness = new Thickness(1), Padding = new Thickness(12, 6, 12, 6), Cursor = Cursors.Hand, MinWidth = 130, Child = label };
        void Reset() => label.Text = vk != 0 ? VibeXASR.Windows.Ui.VkNames.Combo(vk, mods) : L10n.T("tpl.hotkey.unset");
        void Commit(int nvk, int nmods)
        {
            // conflict check (build 205 parity): collides with the main dictation key, or another template
            if (nvk == S.HotkeyVk && nmods == S.HotkeyMods) { label.Text = "⚠ " + L10n.T("tpl.hotkey.conflict"); label.Foreground = Danger; return; }
            foreach (var (i, v, m) in CloudTemplateHotkeys.Parse(S.CloudTemplateHotkeysJson))
                if (i != templateId && v == nvk && m == nmods) { label.Text = "⚠ " + L10n.T("tpl.hotkey.conflict"); label.Foreground = Danger; return; }
            S.CloudTemplateHotkeysJson = CloudTemplateHotkeys.Set(S.CloudTemplateHotkeysJson, templateId, nvk, nmods); _app.ApplyCloudSettings(); Rebuild();
        }
        // OS-level combo capture (WH_KEYBOARD_LL) — robust against the WPF Alt-menu focus steal.
        box.MouseLeftButtonUp += (_, _) =>
        {
            if (_tplHook is not null) return;
            label.Text = L10n.T("dict.hotkey.recording");
            _tplHook = new VibeXASR.Windows.Ui.KeyCaptureHook(combo: true);
            _tplHook.CapturedCombo += (cvk, cmods) => Dispatcher.BeginInvoke(new Action(() =>
            {
                _tplHook?.Dispose(); _tplHook = null;
                if (cvk == 0x1B) { Reset(); return; }   // Esc cancels
                Commit(cvk, cmods);
            }));
            _tplHook.Start();
        };
        Unloaded += (_, _) => { _tplHook?.Dispose(); _tplHook = null; };
        return box;
    }

    private Border Chip(string name, string id, bool active, Action? onDelete)
    {
        var inner = new StackPanel { Orientation = Orientation.Horizontal };
        inner.Children.Add(new TextBlock { Text = name, Foreground = TextB, FontSize = 12, FontWeight = active ? FontWeights.SemiBold : FontWeights.Normal, VerticalAlignment = VerticalAlignment.Center });
        // per-chip copy (share)
        var copy = new TextBlock { Text = _copiedId == id ? "✓" : "⧉", Foreground = _copiedId == id ? Ok : Muted, FontSize = 11, Margin = new Thickness(8, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center, Cursor = Cursors.Hand };
        copy.MouseLeftButtonUp += (_, e) => { e.Handled = true; try { Clipboard.SetText(ContentFor(id)); } catch { } _copiedId = id; Rebuild(); };
        inner.Children.Add(copy);
        if (onDelete is not null)
        {
            var x = new TextBlock { Text = "✕", Foreground = Muted, FontSize = 11, Margin = new Thickness(7, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center, Cursor = Cursors.Hand };
            x.MouseLeftButtonUp += (_, e) => { e.Handled = true; onDelete(); };
            inner.Children.Add(x);
        }
        var chip = new Border { CornerRadius = new CornerRadius(8), Background = active ? AccentSoft : Surface2, BorderBrush = active ? AccentA : Brushes.Transparent, BorderThickness = new Thickness(active ? 1.2 : 0), Padding = new Thickness(11, 6, 11, 6), Margin = new Thickness(0, 0, 8, 8), Cursor = Cursors.Hand, Child = inner };
        chip.MouseLeftButtonUp += (_, _) => { S.CloudActiveTemplate = id; Commit(); };
        return chip;
    }

    private string ContentFor(string id)
    {
        if (id == "auto") return CurrentPromptFor("auto");
        return _templates.FirstOrDefault(t => t.Id == id)?.Content ?? "";
    }

    private string CurrentPrompt() => CurrentPromptFor(S.CloudActiveTemplate);
    private string CurrentPromptFor(string id)
    {
        if (id == "auto")
            return string.IsNullOrEmpty(S.CloudAutoOverride) ? CloudPrompt.BuildAuto(S.CloudNumbers, S.CloudFillers, S.CloudRestate, S.CloudHotwords) : S.CloudAutoOverride;
        return _templates.FirstOrDefault(t => t.Id == id)?.Content ?? "";
    }

    private void Commit(bool rebuild = true)
    {
        S.CloudTemplatesJson = CloudJson.Encode(_templates);
        _app.ApplyCloudSettings();
        if (rebuild) Rebuild();
    }

    [System.Runtime.InteropServices.DllImport("dwmapi.dll")] private static extern int DwmSetWindowAttribute(IntPtr h, int attr, ref int v, int size);
    private void DarkTitleBar() { try { var h = new System.Windows.Interop.WindowInteropHelper(this).Handle; int on = 1; DwmSetWindowAttribute(h, 20, ref on, sizeof(int)); } catch { } }
}
