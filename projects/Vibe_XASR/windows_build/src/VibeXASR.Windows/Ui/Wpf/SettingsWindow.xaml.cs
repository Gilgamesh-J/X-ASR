using System;
using System.Collections.Generic;
using System.Linq;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Shapes;
using VibeXASR.Windows.Dictation;
using VibeXASR.Windows.Storage;
// Disambiguate WPF vs WinForms/Drawing (this project enables both UseWPF + UseWindowsForms).
using Brush = System.Windows.Media.Brush;
using Brushes = System.Windows.Media.Brushes;
using FontFamily = System.Windows.Media.FontFamily;
using Button = System.Windows.Controls.Button;
using ComboBox = System.Windows.Controls.ComboBox;
using ComboBoxItem = System.Windows.Controls.ComboBoxItem;
using TextBox = System.Windows.Controls.TextBox;
using RadioButton = System.Windows.Controls.RadioButton;
using Orientation = System.Windows.Controls.Orientation;
using HorizontalAlignment = System.Windows.HorizontalAlignment;
using VerticalAlignment = System.Windows.VerticalAlignment;
using Cursors = System.Windows.Input.Cursors;
using MessageBox = System.Windows.MessageBox;
using Rectangle = System.Windows.Shapes.Rectangle;
using Ellipse = System.Windows.Shapes.Ellipse;

namespace VibeXASR.Windows.Ui.Wpf;

/// <summary>The redesigned Settings window (WPF). A drop-in alternative to the WinForms SettingsForm,
/// wired to the same <see cref="IAppController"/>. Sidebar nav + a content host rebuilt per tab.</summary>
public partial class SettingsWindow : Window
{
    private readonly IAppController _app;
    private Settings S => _app.Settings;
    private string _tab = "dictation";
    private readonly Dictionary<string, RadioButton> _navButtons = new();

    private static bool Zh => L10n.Resolved is Lang.Zh or Lang.Hant;

    // label is an L10n key, resolved at render time so the nav re-localizes on language change.
    // Order mirrors macOS SettingsView.tabs exactly: 通用 → 听写 → AI润色 → 模型 → 词典 → 口令 → 记录 → 共享 → 权限 → 关于.
    private static readonly (string key, string icon, string label)[] Tabs =
    {
        ("general", "⚙", "tab.general"), ("dictation", "🎙", "tab.dictation"), ("cloud", "✨", "tab.cloud"),
        ("model", "🧠", "tab.model"), ("dictionary", "📖", "tab.dictionary"), ("snippet", "⚡", "tab.snippet"),
        ("history", "📋", "tab.history"), ("share", "🔗", "tab.share"), ("permissions", "🔐", "tab.permissions"),
        ("about", "ⓘ", "tab.about"),
    };

    public SettingsWindow(IAppController app)
    {
        _app = app;
        var startTab = Environment.GetEnvironmentVariable("VIBEXASR_TAB");
        if (!string.IsNullOrEmpty(startTab) && Tabs.Any(t => t.key == startTab)) _tab = startTab;
        InitializeComponent();
        // Safety net: a settings-UI exception must NEVER kill the whole tray app (hosted in the
        // WinForms loop). Log it + swallow so the window degrades instead of crashing the process.
        Dispatcher.UnhandledException += (_, e) =>
        {
            try { System.IO.File.AppendAllText(System.IO.Path.Combine(System.IO.Path.GetTempPath(), "vx_wpf_err.txt"), $"{DateTime.Now:HH:mm:ss}\n{e.Exception}\n\n"); } catch { }
            e.Handled = true;
        };
        SourceInitialized += (_, _) => DarkTitleBar();
        BuildNav();
        SelectTab(_tab);
        Loaded += (_, _) => SelfCapture();
        Closed += (_, _) => StopModelTimer();
    }

    /// <summary>Jump to a tab by key (TrayApp deep-links, e.g. tray "AI 润色" → "cloud").</summary>
    public void ShowTab(string key) { if (Tabs.Any(t => t.key == key)) SelectTab(key); }

    /// <summary>Re-localize the whole window after a language change: rebuild nav + current tab.</summary>
    private void Relocalize()
    {
        Nav.Children.Clear();
        _navButtons.Clear();
        _historyControl = null;   // rebuild the 记录 workspace in the new language
        FullBleed.Content = null;
        BuildNav();
        SelectTab(_tab);
    }

    private void BuildNav()
    {
        foreach (var (key, icon, label) in Tabs)
        {
            var rb = new RadioButton { Style = St("NavItem"), Content = $"{icon}   {L10n.T(label)}", IsChecked = key == _tab };
            var k = key;
            rb.Checked += (_, _) => SelectTab(k);
            _navButtons[key] = rb;
            Nav.Children.Add(rb);
        }
    }

    /// <summary>Rebuild the CURRENT tab without scrolling to top — and DEFERRED, so it never tears
    /// down the control that's mid-click (e.g. a focused prompt-template editor → was crashing).</summary>
    private void RebuildCurrent() => Dispatcher.BeginInvoke(System.Windows.Threading.DispatcherPriority.Background,
        new Action(() => SelectTab(_tab)));

    private HistoryWorkspaceControl? _historyControl;

    private void SelectTab(string key)
    {
        bool sameTab = _tab == key && Content.Children.Count > 0;     // in-tab rebuild → keep scroll
        double keepOffset = sameTab ? ContentScroll.VerticalOffset : 0;
        _tab = key;
        StopModelTimer();   // tear down the previous tab's live model-download poller, if any
        if (_navButtons.TryGetValue(key, out var rb)) rb.IsChecked = true;

        // 记录 is a full-bleed workspace (100% macOS parity) — it replaces the scroller entirely.
        if (key == "history")
        {
            Content.Children.Clear();
            _historyControl ??= new HistoryWorkspaceControl(_app.History);
            FullBleed.Content = _historyControl;
            ContentScroll.Visibility = Visibility.Collapsed;
            FullBleed.Visibility = Visibility.Visible;
            return;
        }
        ContentScroll.Visibility = Visibility.Visible;
        FullBleed.Visibility = Visibility.Collapsed;

        Content.Children.Clear();
        if (sameTab)
            Dispatcher.BeginInvoke(System.Windows.Threading.DispatcherPriority.Loaded, new Action(() => ContentScroll.ScrollToVerticalOffset(keepOffset)));
        else
            ContentScroll.ScrollToTop();
        switch (key)
        {
            case "general": BuildGeneral(); break;
            case "dictation": BuildDictation(); break;
            case "dictionary": BuildDictionary(); break;
            case "snippet": BuildSnippets(); break;
            case "model": BuildModel(); break;
            case "share": BuildShare(); break;
            case "cloud": BuildCloud(); break;
            case "permissions": BuildPermissions(); break;
            case "about": BuildAbout(); break;
            default: BuildPlaceholder(key); break;
        }
    }

    // ============================ tabs ============================

    private void BuildGeneral()
    {
        var lang = Select(new[] { ("auto", L10n.T("lang.auto")), ("zh", "简体中文"), ("zh-Hant", "繁體中文"), ("en", "English"), ("ja", "日本語"), ("ko", "한국어") },
            S.Language, v => { _app.SetLanguage(L10n.FromCode(v)); Relocalize(); }, 170);
        AddGroup(L10n.T("grp.general"),
            Row(L10n.T("gen.lang"), L10n.T("gen.lang.help"), lang),
            Row(L10n.T("gen.launchAtLogin"), L10n.T("gen.launchAtLogin.help"),
                Toggle(S.LaunchAtLogin, v => _app.SetLaunchAtLogin(v))),
            Row(L10n.T("gen.clipboard"), L10n.T("gen.clipboard.help"),
                Toggle(S.ClipboardOverwrite, v => _app.SetClipboardOverwrite(v))),
            Row(L10n.T("gen.launcher"), L10n.T("gen.launcher.help"),
                Toggle(S.LauncherEnabled, v => _app.SetLauncherEnabled(v))));

        // 触发 (trigger): hotkey + trigger mode + dictation mode — high-frequency core interaction,
        // moved up from the 听写 page to mirror macOS build 204's tab reorg.
        AddGroupTitle(L10n.T("grp.trigger"));
        AddCard(
            Row(L10n.T("dict.hotkey"), L10n.T("dict.hotkey.help"), HotkeyButton()),
            Row(L10n.T("dict.trigger"), L10n.T("dict.trigger.help"),
                Segmented(new[] { ("hold", L10n.T("dict.trigger.hold")), ("toggle", L10n.T("dict.trigger.toggle")) },
                    S.Trigger == TriggerMode.Toggle ? "toggle" : "hold",
                    v => _app.SetTrigger(v == "toggle" ? TriggerMode.Toggle : TriggerMode.Hold))));
        Content.Children.Add(BuildModeCards());
    }

    /// <summary>The 听写模式 radio-card block (说完插入 / 逐字 / 持续候机). Lives under 通用 → 触发.</summary>
    private Border BuildModeCards()
    {
        var modeCard = new StackPanel { Margin = new Thickness(16, 12, 16, 12) };
        modeCard.Children.Add(new TextBlock { Text = L10n.T("dict.mode"), Style = St("RowTitle"), FontWeight = FontWeights.SemiBold, Margin = new Thickness(2, 0, 0, 10) });
        var modes = new (DictationMode m, string t, string d, string? warn)[]
        {
            (DictationMode.Paste, L10n.T("dict.mode.paste.title"), L10n.T("dict.mode.paste.desc"), null),
            (DictationMode.Type,  L10n.T("dict.mode.type.title"),  L10n.T("dict.mode.type.desc"),  L10n.T("dict.mode.type.warn")),
            (DictationMode.OnCall, L10n.T("dict.mode.oncall.title"), L10n.T("dict.mode.oncall.desc"), null),
        };
        foreach (var (m, t, d, warn) in modes)
        {
            var card = ModeCard(t, d, S.Mode == m, m == DictationMode.Paste && S.CloudEnabled, warn);
            var cm = m;
            card.MouseLeftButtonUp += (_, _) =>
            {
                if (S.CloudEnabled && cm != DictationMode.Paste)
                {
                    if (MessageBox.Show(L10n.T("dict.mode.conflict.msg"), L10n.T("dict.mode.conflict.title"), MessageBoxButton.YesNo, MessageBoxImage.Question) != MessageBoxResult.Yes) return;
                    S.CloudEnabled = false; _app.ApplyCloudSettings();
                }
                _app.SetMode(cm); SelectTab("general");
            };
            modeCard.Children.Add(card);
        }
        if (S.CloudEnabled)
            modeCard.Children.Insert(1, new TextBlock { Text = L10n.T("dict.mode.lockedByPolish"), Foreground = Br("Warn"), FontSize = 11.5, Margin = new Thickness(2, 0, 0, 8), TextWrapping = TextWrapping.Wrap });
        return new Border { Style = St("Card"), Child = modeCard };
    }

    private void BuildDictation()
    {
        AddGroupTitle(L10n.T("grp.dictation"));

        // overlay stay duration (macOS build 204): how long the 已插入 bar lingers; hover keeps it.
        AddCard(Row(L10n.T("dict.hudStay"), L10n.T("dict.hudStay.help"),
            Segmented(new[] { ("0", L10n.T("dict.hudStay.s0")), ("0.5", L10n.T("dict.hudStay.s05")), ("1", L10n.T("dict.hudStay.s1")), ("2", L10n.T("dict.hudStay.s2")), ("4", L10n.T("dict.hudStay.s4")) },
                HudStayKey(S.HudStaySeconds), v => _app.SetHudStay(double.Parse(v, System.Globalization.CultureInfo.InvariantCulture)))));

        // post-processing toggles
        bool byLLM = S.CloudEnabled;
        AddCard(
            Row(L10n.T("dict.itn"), L10n.T(byLLM ? "dict.byLLM" : "dict.itn.help"), Toggle(S.ItnEnabled, v => _app.SetItn(v), !byLLM)),
            Row(L10n.T("dict.defiller"), L10n.T(byLLM ? "dict.defiller.byLLM" : "dict.defiller.help"), Toggle(S.DefillerEnabled, v => _app.SetDefiller(v), !byLLM)),
            Row(L10n.T("dict.toTraditional"), L10n.T("dict.toTraditional.help"), Toggle(S.OutputTraditional, v => _app.SetOutputTraditional(v))),
            Row(L10n.T("dict.history"), L10n.T("dict.history.help"), Toggle(S.HistoryEnabled, v => _app.SetHistoryEnabled(v))),
            Row(L10n.T("dict.cue"), L10n.T("dict.cue.help"), Toggle(S.CueEnabled, v => { _app.SetCueEnabled(v); SelectTab("dictation"); })));

        if (S.CueEnabled)
            AddCard(
                Row(L10n.T("dict.cueTheme"), null, Select(new[] { ("tick", L10n.T("cue.tick")), ("chime", L10n.T("cue.chime")), ("soft", L10n.T("cue.soft")), ("drop", L10n.T("cue.drop")), ("marimba", L10n.T("cue.marimba")) }, S.CueTheme, v => _app.SetCueTheme(v), 150)),
                Row(L10n.T("dict.cueVol"), null, Select(new[] { ("low", L10n.T("vol.low")), ("med", L10n.T("vol.mid")), ("high", L10n.T("vol.high")) }, S.CueVolume, v => _app.SetCueVolume(v), 150)));
    }

    private void BuildAbout()
    {
        // hero: logo + name + version + check-update + feedback link
        var card = new StackPanel { Margin = new Thickness(0, 22, 0, 8), HorizontalAlignment = HorizontalAlignment.Center };
        var logo = new Border { Width = 72, Height = 72, CornerRadius = new CornerRadius(18), Background = Br("AccentGrad"), HorizontalAlignment = HorizontalAlignment.Center,
            Effect = new System.Windows.Media.Effects.DropShadowEffect { BlurRadius = 24, ShadowDepth = 0, Opacity = 0.5, Color = ((SolidColorBrush)Br("AccentA")).Color } };
        var bars = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
        foreach (var h in new double[] { 20, 34, 24, 15 }) bars.Children.Add(new Rectangle { Width = 5, Height = h, Fill = Brushes.White, RadiusX = 2.5, RadiusY = 2.5, Margin = new Thickness(2.5, 0, 2.5, 0) });
        logo.Child = bars;
        card.Children.Add(logo);
        card.Children.Add(new TextBlock { Text = "Vibe XASR", Foreground = Br("Text"), FontSize = 20, FontWeight = FontWeights.Bold, HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 12, 0, 2) });
        var disp = System.Windows.Forms.Application.ProductVersion; var plus = disp.IndexOf('+'); if (plus >= 0) disp = disp[..plus];
        card.Children.Add(new TextBlock { Text = L10n.T("about.version", disp), Foreground = Br("TextMuted"), FontSize = 11.5, FontFamily = new FontFamily("Cascadia Mono, Consolas"), HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 0, 0, 16) });
        var upd = new Button { Style = St("Ghost"), Content = "⟳  " + L10n.Loc("检查更新", "Check for updates", "アップデートを確認", "업데이트 확인"), HorizontalAlignment = HorizontalAlignment.Center, Foreground = Br("AccentB") };
        upd.Click += (_, _) => Updater.CheckForUpdatesUi();
        card.Children.Add(upd);
        var fb = Link(L10n.T("about.feedback"), "https://github.com/Gilgamesh-J/X-ASR/issues");
        fb.HorizontalAlignment = HorizontalAlignment.Center; fb.Margin = new Thickness(0, 12, 0, 0);
        card.Children.Add(fb);
        Content.Children.Add(card);

        // GitHub issue form — fill 3 fields → opens a prefilled "New issue" page
        var form = new StackPanel { Margin = new Thickness(18, 14, 18, 14) };
        form.Children.Add(new TextBlock { Text = L10n.Loc("反馈问题 · 一键提交到 GitHub", "Report a problem · one-tap to GitHub", "問題を報告 · ワンタップで GitHub へ", "문제 신고 · 원터치로 GitHub 제출"), Foreground = Br("Text"), FontSize = 14, FontWeight = FontWeights.SemiBold });
        form.Children.Add(new TextBlock { Text = L10n.Loc("填好下面三项,点按钮会打开已预填内容的 GitHub「新建 issue」页,确认后提交即可。", "Fill these, then the button opens a prefilled GitHub New-issue page.", "以下の3項目を入力すると、内容が事前入力された GitHub「新規 issue」ページが開きます。", "아래 세 항목을 입력하면 내용이 미리 채워진 GitHub '새 issue' 페이지가 열립니다."), Style = St("RowDesc"), Margin = new Thickness(0, 4, 0, 8), TextWrapping = TextWrapping.Wrap });
        var fFeature = AboutField(L10n.Loc("使用的功能", "Feature used", "使用した機能", "사용한 기능"), L10n.Loc("如:云端润色 / 听写插入 / 热词修正", "e.g. cloud polish / dictation / hotwords", "例:クラウド整形 / 音声入力 / ホットワード補正", "예: 클라우드 다듬기 / 받아쓰기 / 핫워드 교정"));
        var fProblem = AboutField(L10n.Loc("遇到的问题", "Problem", "発生した問題", "발생한 문제"), L10n.Loc("具体现象、什么时候出现、能否复现", "What happened, when, can it reproduce", "具体的な症状、発生時期、再現可否", "구체적인 증상, 발생 시점, 재현 가능 여부"), 64);
        var fExpect = AboutField(L10n.Loc("预期结果", "Expected", "期待する結果", "예상 결과"), L10n.Loc("你期望它怎样", "What you expected", "どうなることを期待したか", "어떻게 동작하기를 기대했는지"));
        form.Children.Add(fFeature.label); form.Children.Add(fFeature.visual);
        form.Children.Add(fProblem.label); form.Children.Add(fProblem.visual);
        form.Children.Add(fExpect.label); form.Children.Add(fExpect.visual);
        var submit = new Button { Style = St("Solid"), Content = "✈  " + L10n.Loc("在 GitHub 提交(已预填)", "Open prefilled GitHub issue", "GitHub で送信(事前入力済み)", "GitHub에 제출(미리 채워짐)"), HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 12, 0, 0) };
        submit.Click += (_, _) =>
        {
            string title = Uri.EscapeDataString($"[Windows] {L10n.Loc("反馈", "Feedback", "フィードバック", "피드백")}: {Trunc(fProblem.box.Text, 50)}");
            string body = Uri.EscapeDataString(
                $"### {L10n.Loc("使用的功能", "Feature", "使用した機能", "사용한 기능")}\n{fFeature.box.Text}\n\n### {L10n.Loc("遇到的问题", "Problem", "発生した問題", "발생한 문제")}\n{fProblem.box.Text}\n\n### {L10n.Loc("预期结果", "Expected", "期待する結果", "예상 결과")}\n{fExpect.box.Text}\n\n---\nVibe XASR {disp} · Windows");
            try { System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo($"https://github.com/Gilgamesh-J/X-ASR/issues/new?title={title}&body={body}") { UseShellExecute = true }); } catch { }
        };
        form.Children.Add(submit);
        Content.Children.Add(new Border { Style = St("Card"), Child = form });

        // X-ASR credit card
        var credit = new StackPanel { Margin = new Thickness(18, 14, 18, 14), HorizontalAlignment = HorizontalAlignment.Center };
        var ct = Link(L10n.T("about.xasr.title"), "https://github.com/Gilgamesh-J/X-ASR"); ct.FontSize = 14; ct.FontWeight = FontWeights.Bold; ct.HorizontalAlignment = HorizontalAlignment.Center;
        credit.Children.Add(ct);
        credit.Children.Add(new TextBlock { Text = L10n.T("about.xasr.desc"), Style = St("RowDesc"), TextAlignment = TextAlignment.Center, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 6, 0, 6) });
        var repo = Link(L10n.T("about.xasr.repo"), "https://huggingface.co/GilgameshWind/X-ASR-zh-en"); repo.HorizontalAlignment = HorizontalAlignment.Center; repo.Foreground = Br("AccentB");
        credit.Children.Add(repo);
        Content.Children.Add(new Border { Style = St("Card"), Background = Br("AccentSoft"), Child = credit });

        Content.Children.Add(new TextBlock { Text = L10n.T("about.local"), Foreground = Br("TextMuted"), FontSize = 11, FontFamily = new FontFamily("Cascadia Mono, Consolas"), HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 12, 0, 8) });
    }

    private (TextBlock label, FrameworkElement visual, TextBox box) AboutField(string label, string placeholder, double height = 0)
    {
        var lbl = new TextBlock { Text = label, Style = St("RowDesc"), Margin = new Thickness(2, 8, 0, 4) };
        var box = new TextBox { Style = St("FieldBox"), FontSize = 12.5 };
        if (height > 0) { box.Height = height; box.AcceptsReturn = true; box.TextWrapping = TextWrapping.Wrap; box.VerticalContentAlignment = VerticalAlignment.Top; }
        var water = new TextBlock { Text = placeholder, Foreground = Br("TextMuted"), FontSize = 12.5, Margin = new Thickness(13, 0, 0, 0), VerticalAlignment = height > 0 ? VerticalAlignment.Top : VerticalAlignment.Center, IsHitTestVisible = false };
        if (height > 0) water.Margin = new Thickness(13, 10, 0, 0);
        box.TextChanged += (_, _) => water.Visibility = string.IsNullOrEmpty(box.Text) ? Visibility.Visible : Visibility.Collapsed;
        var grid = new Grid(); grid.Children.Add(box); grid.Children.Add(water);
        return (lbl, grid, box);
    }

    private static string Trunc(string s, int n) { s = (s ?? "").Replace("\n", " ").Trim(); return s.Length > n ? s[..n] : s; }

    /// <summary>Snap a stored HudStaySeconds value to the nearest segmented option key.</summary>
    private static string HudStayKey(double v) => v <= 0.25 ? "0" : v <= 0.75 ? "0.5" : v <= 1.5 ? "1" : v <= 3 ? "2" : "4";

    /// <summary>记录 entry: History is a standalone window — this tab opens it (and offers a re-open button).</summary>
    private void BuildHistoryEntry()
    {
        AddGroupTitle(L10n.T("tab.history"));
        var sp = new StackPanel { Margin = new Thickness(20, 22, 20, 22), HorizontalAlignment = HorizontalAlignment.Center };
        sp.Children.Add(new TextBlock { Text = "🗂", FontSize = 40, HorizontalAlignment = HorizontalAlignment.Center });
        sp.Children.Add(new TextBlock { Text = L10n.T("history.entry.desc"), Foreground = Br("TextMuted"), FontSize = 12.5, TextAlignment = TextAlignment.Center, TextWrapping = TextWrapping.Wrap, MaxWidth = 420, Margin = new Thickness(0, 12, 0, 16) });
        var open = new Button { Style = St("Solid"), Content = "🗂  " + L10n.T("history.entry.open"), HorizontalAlignment = HorizontalAlignment.Center };
        open.Click += (_, _) => _app.OpenHistory();
        sp.Children.Add(open);
        Content.Children.Add(new Border { Style = St("Card"), Child = sp });
        // also open it immediately when navigating here (idempotent: just activates if already open)
        Dispatcher.BeginInvoke(System.Windows.Threading.DispatcherPriority.Background, new Action(() => _app.OpenHistory()));
    }

    private void BuildPlaceholder(string key)
    {
        var label = L10n.T(Tabs.FirstOrDefault(t => t.key == key).label);
        AddGroupTitle(label);
        var sp = new StackPanel { Margin = new Thickness(20, 26, 20, 26) };
        sp.Children.Add(new TextBlock { Text = "🚧", FontSize = 28, HorizontalAlignment = HorizontalAlignment.Center });
        sp.Children.Add(new TextBlock { Text = L10n.Loc($"「{label}」正在迁移到新界面…", $"“{label}” is being migrated…", $"「{label}」を新しい画面に移行中…", $"'{label}'을(를) 새 화면으로 이전 중…"), Foreground = Br("TextMuted"), FontSize = 12.5, HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 10, 0, 0) });
        Content.Children.Add(new Border { Style = St("Card"), Child = sp });
    }

    // ============================ helpers ============================

    private Style St(string key) => (Style)FindResource(key);
    private Brush Br(string key) => (Brush)FindResource(key);

    private void AddGroupTitle(string text) => Content.Children.Add(new TextBlock { Text = text, Style = St("GroupTitle") });
    private void AddGroup(string title, params UIElement[] rows) { AddGroupTitle(title); AddCard(rows); }
    private void AddCard(params UIElement[] rows) => Content.Children.Add(Card(rows));

    private Border Card(params UIElement[] rows)
    {
        var sp = new StackPanel { Margin = new Thickness(18, 4, 18, 4) };
        for (int i = 0; i < rows.Length; i++)
        {
            if (i > 0) sp.Children.Add(new Border { Height = 1, Background = Br("Hairline") });
            sp.Children.Add(rows[i]);
        }
        return new Border { Style = St("Card"), Child = sp };
    }

    private Grid Row(string title, string? desc, FrameworkElement control)
    {
        var g = new Grid { Margin = new Thickness(0, 12, 0, 12) };
        g.ColumnDefinitions.Add(new ColumnDefinition());
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var left = new StackPanel { VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 14, 0) };
        left.Children.Add(new TextBlock { Text = title, Style = St("RowTitle") });
        if (!string.IsNullOrEmpty(desc)) left.Children.Add(new TextBlock { Text = desc, Style = St("RowDesc") });
        Grid.SetColumn(left, 0); g.Children.Add(left);
        control.VerticalAlignment = VerticalAlignment.Center;
        Grid.SetColumn(control, 1); g.Children.Add(control);
        return g;
    }

    private ToggleButton Toggle(bool val, Action<bool> onChange, bool enabled = true)
    {
        var t = new ToggleButton { Style = St("Toggle"), IsChecked = val, IsEnabled = enabled, HorizontalAlignment = HorizontalAlignment.Right };
        t.Checked += (_, _) => onChange(true);
        t.Unchecked += (_, _) => onChange(false);
        return t;
    }

    private ComboBox Select((string val, string label)[] options, string value, Action<string> onChange, double width = 170)
    {
        var c = new ComboBox { Style = St("Select"), Width = width, ItemContainerStyle = St("SelectItem"), HorizontalAlignment = HorizontalAlignment.Right };
        foreach (var (v, l) in options) c.Items.Add(new ComboBoxItem { Content = l, Tag = v });
        c.SelectedIndex = Math.Max(0, Array.FindIndex(options, o => o.val == value));
        c.SelectionChanged += (_, _) => { if (c.SelectedItem is ComboBoxItem it) onChange((string)it.Tag); };
        return c;
    }

    private KeyCaptureHook? _hotkeyHook;
    private Button HotkeyButton()
    {
        var b = new Button { Style = St("Ghost"), Content = VkNames.Combo(S.HotkeyVk, S.HotkeyMods), HorizontalAlignment = HorizontalAlignment.Right, MinWidth = 110 };
        // Capture the combo at the OS level (WH_KEYBOARD_LL) rather than via WPF key events — a WPF
        // button loses focus when Alt enters menu-mode, which would drop Alt combos. The hook swallows
        // the keys while recording so they never leak to the app behind.
        b.Click += (_, _) =>
        {
            if (_hotkeyHook is not null) return;
            b.Content = L10n.T("dict.hotkey.recording");
            _hotkeyHook = new KeyCaptureHook(combo: true);
            _hotkeyHook.CapturedCombo += (vk, mods) => Dispatcher.BeginInvoke(new Action(() =>
            {
                _hotkeyHook?.Dispose(); _hotkeyHook = null;
                if (vk == 0x1B) { b.Content = VkNames.Combo(S.HotkeyVk, S.HotkeyMods); return; }   // Esc cancels
                _app.SetHotkey(vk, mods); b.Content = VkNames.Combo(vk, mods);
            }));
            _hotkeyHook.Start();
        };
        b.Unloaded += (_, _) => { _hotkeyHook?.Dispose(); _hotkeyHook = null; };
        return b;
    }

    private Border ModeCard(string title, string desc, bool selected, bool recommended, string? warn = null)
    {
        var grid = new Grid();
        grid.ColumnDefinitions.Add(new ColumnDefinition());
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var left = new StackPanel();
        var titleRow = new StackPanel { Orientation = Orientation.Horizontal };
        titleRow.Children.Add(new TextBlock { Text = title, Foreground = Br("Text"), FontSize = 13, FontWeight = selected ? FontWeights.SemiBold : FontWeights.Normal });
        if (recommended)
            titleRow.Children.Add(new Border { Style = St("Badge"), Margin = new Thickness(8, 0, 0, 0), Child = new TextBlock { Text = L10n.T("badge.recommended"), Foreground = Br("AccentA"), FontSize = 10, FontWeight = FontWeights.SemiBold } });
        left.Children.Add(titleRow);
        left.Children.Add(new TextBlock { Text = desc, Style = St("RowDesc") });
        if (!string.IsNullOrEmpty(warn))
            left.Children.Add(new TextBlock { Text = warn, Foreground = Br("Warn"), FontSize = 11, Margin = new Thickness(0, 4, 0, 0), TextWrapping = TextWrapping.Wrap });
        Grid.SetColumn(left, 0); grid.Children.Add(left);
        var dot = new Ellipse { Width = 18, Height = 18, Stroke = selected ? Br("AccentA") : Br("Hairline"), StrokeThickness = selected ? 5 : 1.5, VerticalAlignment = VerticalAlignment.Center };
        Grid.SetColumn(dot, 1); grid.Children.Add(dot);
        return new Border
        {
            CornerRadius = new CornerRadius(10), Padding = new Thickness(14, 11, 14, 11), Margin = new Thickness(0, 0, 0, 8), Cursor = Cursors.Hand,
            Background = selected ? Br("AccentSoft") : Br("Field"),
            BorderBrush = selected ? Br("AccentA") : Br("Hairline"), BorderThickness = new Thickness(selected ? 1.4 : 1),
            Child = grid,
        };
    }

    private TextBlock Link(string text, string url)
    {
        var t = new TextBlock { Text = text, Foreground = Br("AccentA"), FontSize = 12, Cursor = Cursors.Hand };
        t.MouseLeftButtonUp += (_, _) => { try { System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(url) { UseShellExecute = true }); } catch { } };
        return t;
    }

    // ============================ chrome + dev capture ============================

    [DllImport("dwmapi.dll")] private static extern int DwmSetWindowAttribute(IntPtr h, int attr, ref int v, int size);
    private void DarkTitleBar() { try { var h = new WindowInteropHelper(this).Handle; int on = 1; DwmSetWindowAttribute(h, 20, ref on, sizeof(int)); } catch { } }

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
                using var fs = System.IO.File.Create(shot);
                enc.Save(fs);
            }
            catch { }
            if (System.Windows.Application.Current is { } a) a.Shutdown(); else Close();
        }));
    }
}
