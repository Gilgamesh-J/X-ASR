using System;
using System.Collections.Generic;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Media;
using System.Windows.Shapes;
using System.Windows.Threading;
using VibeXASR.Windows.Lexicon;
using VibeXASR.Windows.Models;
using VibeXASR.Windows.Refine;
using VibeXASR.Windows.Storage;
// Same WPF-vs-WinForms disambiguation as the main partial.
using Brush = System.Windows.Media.Brush;
using Brushes = System.Windows.Media.Brushes;
using FontFamily = System.Windows.Media.FontFamily;
using Button = System.Windows.Controls.Button;
using ComboBox = System.Windows.Controls.ComboBox;
using TextBox = System.Windows.Controls.TextBox;
using Orientation = System.Windows.Controls.Orientation;
using HorizontalAlignment = System.Windows.HorizontalAlignment;
using VerticalAlignment = System.Windows.VerticalAlignment;
using Cursors = System.Windows.Input.Cursors;
using MessageBox = System.Windows.MessageBox;
using Rectangle = System.Windows.Shapes.Rectangle;
using Ellipse = System.Windows.Shapes.Ellipse;

namespace VibeXASR.Windows.Ui.Wpf;

// The remaining Settings tabs (词典 / 口令 / 模型 / 共享 / AI 润色 / 权限), wired to IAppController.
public partial class SettingsWindow
{
    // ============================ 词典 (dictionary) ============================

    private List<string> _hotwords = new(); private bool _hwLoaded; private int _hwPage;
    private sealed class RepRule { public string From = ""; public string To = ""; }
    private List<RepRule> _reps = new(); private bool _repLoaded;
    private const int HwPerPage = 5;

    private string HwText() => string.Join("\n", _hotwords.Select(w => w.Trim()).Where(w => w.Length > 0));
    private string RepText() => string.Join("\n", _reps.Where(r => r.From.Trim().Length > 0).Select(r => $"{r.From.Trim()} => {r.To.Trim()}"));
    private void ApplyHotwords() => _app.SetHotwords(S.HotwordsEnabled, HwText(), S.HotwordsScore);
    private void ApplyReps() => _app.SetReplacements(S.ReplacementsEnabled, RepText());

    private void BuildDictionary()
    {
        if (!_hwLoaded) { _hotwords = (S.HotwordsText ?? "").Split('\n').Select(s => s.Trim()).Where(s => s.Length > 0).ToList(); _hwLoaded = true; }
        if (!_repLoaded) { _reps = Replacements.Parse(S.ReplacementsText).Select(r => new RepRule { From = r.From, To = r.To }).ToList(); _repLoaded = true; }

        // ===== custom words =====
        AddGroupTitle(L10n.T("grp.hotwords"));
        AddCard(Row(L10n.T("hw.enable"), L10n.T("hw.enable.help"),
            Toggle(S.HotwordsEnabled, v => { _app.SetHotwords(v, HwText(), S.HotwordsScore); SelectTab("dictionary"); })));

        if (S.HotwordsEnabled)
        {
            // words editor (paginated)
            var wsp = new StackPanel { Margin = new Thickness(18, 12, 18, 12) };
            wsp.Children.Add(new TextBlock { Text = L10n.T("hw.editor.title"), Foreground = Br("Text"), FontSize = 13.5, FontWeight = FontWeights.SemiBold });
            wsp.Children.Add(new TextBlock { Text = L10n.T("hw.editor.help"), Style = St("RowDesc"), Margin = new Thickness(0, 4, 0, 8), TextWrapping = TextWrapping.Wrap });
            int total = _hotwords.Count, pages = Math.Max(1, (total + HwPerPage - 1) / HwPerPage);
            _hwPage = Math.Min(Math.Max(0, _hwPage), pages - 1);
            if (total == 0)
                wsp.Children.Add(new TextBlock { Text = L10n.T("hw.empty.hint"), Style = St("RowDesc"), Margin = new Thickness(0, 4, 0, 4) });
            for (int i = _hwPage * HwPerPage; i < Math.Min(total, _hwPage * HwPerPage + HwPerPage); i++)
            {
                int idx = i;
                var g = new Grid { Margin = new Thickness(0, 0, 0, 8) };
                g.ColumnDefinitions.Add(new ColumnDefinition());
                g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
                var f = new TextBox { Style = St("FieldBox"), Text = _hotwords[idx], FontFamily = new FontFamily("Cascadia Mono, Consolas"), FontSize = 13 };
                f.LostFocus += (_, _) => { _hotwords[idx] = f.Text; ApplyHotwords(); };
                Grid.SetColumn(f, 0); g.Children.Add(f);
                var del = RedMinus(() => { _hotwords.RemoveAt(idx); ApplyHotwords(); SelectTab("dictionary"); });
                del.Margin = new Thickness(10, 0, 0, 0);
                Grid.SetColumn(del, 1); g.Children.Add(del);
                wsp.Children.Add(g);
            }
            if (pages > 1) wsp.Children.Add(Pager(_hwPage, pages, p => { _hwPage = p; SelectTab("dictionary"); }));
            var addHw = new TextBlock { Text = "⊕ " + L10n.T("hw.add"), Foreground = Br("AccentA"), FontSize = 13, Margin = new Thickness(0, 6, 0, 0), Cursor = Cursors.Hand };
            addHw.MouseLeftButtonUp += (_, _) => { _hotwords.Add(""); _hwPage = (_hotwords.Count - 1) / HwPerPage; SelectTab("dictionary"); };
            wsp.Children.Add(addHw);
            Content.Children.Add(new Border { Style = St("Card"), Child = wsp });

            // strength (segmented) + homophone + footer
            AddCard(
                Row(L10n.T("hw.score"), L10n.T("hw.score.help"),
                    Segmented(new[] { ("3", L10n.T("hw.score.low")), ("5", L10n.T("hw.score.mid")), ("7", L10n.T("hw.score.high")) },
                        ((int)S.HotwordsScore).ToString(), v => { _app.SetHotwords(S.HotwordsEnabled, HwText(), double.Parse(v)); SelectTab("dictionary"); })),
                Row(L10n.T("hw.pinyin"), L10n.T("hw.pinyin.help"), Toggle(S.PinyinFuzzyEnabled, v => _app.SetPinyinFuzzy(v))));
            AddFooter(L10n.T("hw.count", _hotwords.Count(w => !string.IsNullOrWhiteSpace(w))), () => { ApplyHotwords(); SelectTab("dictionary"); },
                onExport: () => ExportTextFile(HwText(), "vibe-hotwords.txt"),
                onImport: () =>
                {
                    var t = ImportTextFile();
                    if (t is null) return;
                    _hotwords = t.Split('\n').Select(s => s.Trim()).Where(s => s.Length > 0).ToList();
                    _hwPage = 0; ApplyHotwords(); SelectTab("dictionary");
                });
        }

        // ===== replacements =====
        AddGroupTitle(L10n.T("grp.replace"));
        AddCard(Row(L10n.T("rep.enable"), L10n.T("rep.enable.help"),
            Toggle(S.ReplacementsEnabled, v => { _app.SetReplacements(v, RepText()); SelectTab("dictionary"); })));

        if (S.ReplacementsEnabled)
        {
            var rsp = new StackPanel { Margin = new Thickness(18, 12, 18, 12) };
            rsp.Children.Add(new TextBlock { Text = L10n.T("rep.editor.title"), Foreground = Br("Text"), FontSize = 13.5, FontWeight = FontWeights.SemiBold });
            rsp.Children.Add(new TextBlock { Text = L10n.T("rep.editor.help"), Style = St("RowDesc"), Margin = new Thickness(0, 4, 0, 8), TextWrapping = TextWrapping.Wrap });
            // column headers
            var hg = new Grid { Margin = new Thickness(0, 0, 0, 4) };
            hg.ColumnDefinitions.Add(new ColumnDefinition());
            hg.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(30) });
            hg.ColumnDefinitions.Add(new ColumnDefinition());
            hg.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(38) });
            var hl = new TextBlock { Text = L10n.T("rep.col.from"), Style = St("RowDesc") }; Grid.SetColumn(hl, 0); hg.Children.Add(hl);
            var hr = new TextBlock { Text = L10n.T("rep.col.to"), Style = St("RowDesc") }; Grid.SetColumn(hr, 2); hg.Children.Add(hr);
            rsp.Children.Add(hg);
            if (_reps.Count == 0)
                rsp.Children.Add(new TextBlock { Text = L10n.T("rep.empty.hint"), Style = St("RowDesc"), Margin = new Thickness(0, 4, 0, 4) });
            for (int i = 0; i < _reps.Count; i++)
            {
                int idx = i; var r = _reps[i];
                var g = new Grid { Margin = new Thickness(0, 0, 0, 8) };
                g.ColumnDefinitions.Add(new ColumnDefinition());
                g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(30) });
                g.ColumnDefinitions.Add(new ColumnDefinition());
                g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(38) });
                var from = new TextBox { Style = St("FieldBox"), Text = r.From, FontFamily = new FontFamily("Cascadia Mono, Consolas"), FontSize = 13 };
                from.LostFocus += (_, _) => { r.From = from.Text; ApplyReps(); };
                Grid.SetColumn(from, 0); g.Children.Add(from);
                var arrow = new TextBlock { Text = "→", Foreground = Br("TextMuted"), FontSize = 14, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center }; Grid.SetColumn(arrow, 1); g.Children.Add(arrow);
                var to = new TextBox { Style = St("FieldBox"), Text = r.To, FontFamily = new FontFamily("Cascadia Mono, Consolas"), FontSize = 13 };
                to.LostFocus += (_, _) => { r.To = to.Text; ApplyReps(); };
                Grid.SetColumn(to, 2); g.Children.Add(to);
                var del = RedMinus(() => { _reps.RemoveAt(idx); ApplyReps(); SelectTab("dictionary"); }); del.HorizontalAlignment = HorizontalAlignment.Right;
                Grid.SetColumn(del, 3); g.Children.Add(del);
                rsp.Children.Add(g);
            }
            var addRep = new TextBlock { Text = "⊕ " + L10n.T("rep.add"), Foreground = Br("AccentA"), FontSize = 13, Margin = new Thickness(0, 6, 0, 0), Cursor = Cursors.Hand };
            addRep.MouseLeftButtonUp += (_, _) => { _reps.Add(new RepRule()); SelectTab("dictionary"); };
            rsp.Children.Add(addRep);
            Content.Children.Add(new Border { Style = St("Card"), Child = rsp });
            AddFooter(L10n.T("rep.count", _reps.Count(r => r.From.Trim().Length > 0)), () => { ApplyReps(); SelectTab("dictionary"); },
                onExport: () => ExportTextFile(RepText(), "vibe-replacements.txt"),
                onImport: () =>
                {
                    var t = ImportTextFile();
                    if (t is null) return;
                    _reps = Replacements.Parse(t).Select(r => new RepRule { From = r.From, To = r.To }).ToList();
                    ApplyReps(); SelectTab("dictionary");
                });
        }
    }

    private Border RedMinus(Action onClick)
    {
        var b = new Border { Width = 28, Height = 28, CornerRadius = new CornerRadius(14), Background = new SolidColorBrush(WithAlpha(((SolidColorBrush)Br("Danger")).Color, 40)), VerticalAlignment = VerticalAlignment.Center, Cursor = Cursors.Hand,
            Child = new TextBlock { Text = "⊖", Foreground = Br("Danger"), FontSize = 15, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center } };
        b.MouseLeftButtonUp += (_, _) => onClick();
        return b;
    }

    private FrameworkElement Pager(int page, int pages, Action<int> go)
    {
        var sp = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 4, 0, 2) };
        TextBlock Arrow(string t, bool on, int target) { var a = new TextBlock { Text = t, Foreground = Br(on ? "AccentA" : "TextMuted"), FontSize = 15, Margin = new Thickness(10, 0, 10, 0), Cursor = on ? Cursors.Hand : Cursors.Arrow, VerticalAlignment = VerticalAlignment.Center }; if (on) a.MouseLeftButtonUp += (_, _) => go(target); return a; }
        sp.Children.Add(Arrow("‹", page > 0, page - 1));
        sp.Children.Add(new TextBlock { Text = $"{page + 1} / {pages}", Foreground = Br("Text"), FontSize = 12.5, FontFamily = new FontFamily("Cascadia Mono, Consolas"), VerticalAlignment = VerticalAlignment.Center });
        sp.Children.Add(Arrow("›", page < pages - 1, page + 1));
        return sp;
    }

    private FrameworkElement Segmented((string val, string label)[] opts, string value, Action<string> onPick)
    {
        var outer = new Border { CornerRadius = new CornerRadius(8), Background = Br("Field"), Padding = new Thickness(3), HorizontalAlignment = HorizontalAlignment.Right };
        var sp = new StackPanel { Orientation = Orientation.Horizontal };
        foreach (var (v, l) in opts)
        {
            bool sel = v == value;
            var seg = new Border { CornerRadius = new CornerRadius(6), Background = sel ? Br("AccentSoft") : System.Windows.Media.Brushes.Transparent, Padding = new Thickness(15, 5, 15, 5), Cursor = Cursors.Hand,
                Child = new TextBlock { Text = l, Foreground = sel ? Br("AccentA") : Br("TextMuted"), FontSize = 12.5, FontWeight = sel ? FontWeights.SemiBold : FontWeights.Normal } };
            seg.MouseLeftButtonUp += (_, _) => onPick(v);
            sp.Children.Add(seg);
        }
        outer.Child = sp;
        return outer;
    }

    private void AddFooter(string countText, Action onSave, Action? onExport = null, Action? onImport = null)
    {
        var g = new Grid { Margin = new Thickness(20, 6, 8, 2) };
        g.ColumnDefinitions.Add(new ColumnDefinition());
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        g.Children.Add(new TextBlock { Text = countText, Foreground = Br("TextMuted"), FontSize = 12, VerticalAlignment = VerticalAlignment.Center });
        var btns = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right };
        if (onExport is not null)
        {
            var ex = new Button { Style = St("Ghost"), Content = L10n.T("io.export"), Margin = new Thickness(0, 0, 8, 0) };
            ex.Click += (_, _) => onExport();
            btns.Children.Add(ex);
        }
        if (onImport is not null)
        {
            var im = new Button { Style = St("Ghost"), Content = L10n.T("io.import"), Margin = new Thickness(0, 0, 8, 0) };
            im.Click += (_, _) => onImport();
            btns.Children.Add(im);
        }
        var save = new Button { Style = St("Solid"), Content = L10n.T("hw.save") };
        save.Click += (_, _) => onSave();
        btns.Children.Add(save);
        Grid.SetColumn(btns, 1); g.Children.Add(btns);
        Content.Children.Add(g);
    }

    // ---- import / export (macOS LexiconIO parity) ----
    private static string? ImportTextFile()
    {
        var d = new Microsoft.Win32.OpenFileDialog { Filter = "Text / JSON (*.txt;*.json)|*.txt;*.json|All files (*.*)|*.*" };
        try { return d.ShowDialog() == true ? System.IO.File.ReadAllText(d.FileName) : null; }
        catch { return null; }
    }
    private static void ExportTextFile(string content, string suggestedName)
    {
        var ext = suggestedName.EndsWith(".json", StringComparison.OrdinalIgnoreCase) ? "JSON (*.json)|*.json" : "Text (*.txt)|*.txt";
        var d = new Microsoft.Win32.SaveFileDialog { FileName = suggestedName, Filter = ext + "|All files (*.*)|*.*" };
        try { if (d.ShowDialog() == true) System.IO.File.WriteAllText(d.FileName, content); }
        catch { }
    }

    // ============================ 口令 (voice snippets) ============================

    private sealed class Snip { public string Trigger = ""; public string Text = ""; }

    private List<Snip> _snips = new();
    private bool _snipsLoaded;

    private void BuildSnippets()
    {
        if (!_snipsLoaded) { _snips = ParseSnips(S.SnippetsJson); _snipsLoaded = true; }
        AddGroupTitle(L10n.T("grp.snippet"));

        AddCard(Row(L10n.T("snip.enable"), L10n.T("snip.enable.help"),
            Toggle(S.SnippetsEnabled, v => { _app.SetSnippets(v, S.SnippetsJson); SelectTab("snippet"); })));

        for (int i = 0; i < _snips.Count; i++)
        {
            int idx = i;
            var s = _snips[i];
            // trigger row: field + red ⊖ delete
            var trigGrid = new Grid();
            trigGrid.ColumnDefinitions.Add(new ColumnDefinition());
            trigGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            var trig = new TextBox { Style = St("FieldBox"), Text = s.Trigger, FontFamily = new FontFamily("Cascadia Mono, Consolas"), FontSize = 13 };
            trig.LostFocus += (_, _) => { s.Trigger = trig.Text; SaveSnips(); };
            Grid.SetColumn(trig, 0); trigGrid.Children.Add(trig);
            var del = new Border { Width = 26, Height = 26, CornerRadius = new CornerRadius(13), Background = new SolidColorBrush(WithAlpha(((SolidColorBrush)Br("Danger")).Color, 38)), Margin = new Thickness(10, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center, Cursor = Cursors.Hand,
                Child = new TextBlock { Text = "⊖", Foreground = Br("Danger"), FontSize = 14, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center } };
            del.MouseLeftButtonUp += (_, _) => { _snips.RemoveAt(idx); SaveSnips(); SelectTab("snippet"); };
            Grid.SetColumn(del, 1); trigGrid.Children.Add(del);
            var exp = Multiline(s.Text, 64, t => { s.Text = t; SaveSnips(); });
            AddCardRaw(trigGrid, exp);
        }

        var add = new TextBlock { Text = "⊕ " + L10n.T("snip.add"), Foreground = Br("AccentA"), FontSize = 13, Margin = new Thickness(20, 4, 0, 4), Cursor = Cursors.Hand };
        add.MouseLeftButtonUp += (_, _) => { _snips.Add(new Snip()); SaveSnips(); SelectTab("snippet"); };
        Content.Children.Add(add);

        // footer: count + save
        var footGrid = new Grid { Margin = new Thickness(20, 6, 8, 0) };
        footGrid.ColumnDefinitions.Add(new ColumnDefinition());
        footGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        footGrid.Children.Add(new TextBlock { Text = L10n.T("snip.count", _snips.Count), Foreground = Br("TextMuted"), FontSize = 12, VerticalAlignment = VerticalAlignment.Center });
        var footBtns = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right };
        var exBtn = new Button { Style = St("Ghost"), Content = L10n.T("io.export"), Margin = new Thickness(0, 0, 8, 0) };
        exBtn.Click += (_, _) => ExportTextFile(SerializeSnips(_snips), "vibe-snippets.json");
        footBtns.Children.Add(exBtn);
        var imBtn = new Button { Style = St("Ghost"), Content = L10n.T("io.import"), Margin = new Thickness(0, 0, 8, 0) };
        imBtn.Click += (_, _) => { var t = ImportTextFile(); if (t is null) return; _snips = ParseSnips(t); SaveSnips(); SelectTab("snippet"); };
        footBtns.Children.Add(imBtn);
        var saveBtn = new Button { Style = St("Solid"), Content = L10n.T("hw.save") };
        saveBtn.Click += (_, _) => { SaveSnips(); SelectTab("snippet"); };
        footBtns.Children.Add(saveBtn);
        Grid.SetColumn(footBtns, 1); footGrid.Children.Add(footBtns);
        Content.Children.Add(footGrid);
    }

    private void SaveSnips() => _app.SetSnippets(S.SnippetsEnabled, SerializeSnips(_snips));

    private static List<Snip> ParseSnips(string? json)
    {
        var list = new List<Snip>();
        if (string.IsNullOrWhiteSpace(json)) return list;
        try
        {
            using var doc = System.Text.Json.JsonDocument.Parse(json);
            if (doc.RootElement.ValueKind != System.Text.Json.JsonValueKind.Array) return list;
            foreach (var el in doc.RootElement.EnumerateArray())
            {
                if (el.ValueKind != System.Text.Json.JsonValueKind.Object) continue;
                var t = el.TryGetProperty("t", out var tv) ? tv.GetString() : null;
                var x = el.TryGetProperty("x", out var xv) ? xv.GetString() : null;
                if (!string.IsNullOrEmpty(t)) list.Add(new Snip { Trigger = t, Text = x ?? "" });
            }
        }
        catch { }
        return list;
    }

    private static string SerializeSnips(List<Snip> rows)
    {
        var arr = rows.Where(r => !string.IsNullOrWhiteSpace(r.Trigger))
            .Select(r => new Dictionary<string, string> { ["t"] = r.Trigger.Trim(), ["x"] = (r.Text ?? "").Replace("\r\n", "\n") });
        return System.Text.Json.JsonSerializer.Serialize(arr,
            new System.Text.Json.JsonSerializerOptions { Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping });
    }

    // ============================ 模型 (model) ============================

    private static readonly ModelTier[] TierList = { ModelTier.Ms160, ModelTier.Ms480, ModelTier.Ms960, ModelTier.Ms1920 };

    private void BuildModel()
    {
        AddGroupTitle(L10n.Loc("模型", "Model", "モデル", "모델"));

        var src = ModelSourceX.From(S.ModelSource);

        // headline + quantized badge
        var head = new StackPanel { Margin = new Thickness(16, 12, 16, 12) };
        head.Children.Add(new TextBlock { Text = L10n.T("model.headline.title"), Style = St("RowTitle"), FontWeight = FontWeights.SemiBold });
        head.Children.Add(new TextBlock { Text = L10n.T("model.headline.repo"), Style = St("RowDesc"), FontFamily = new FontFamily("Cascadia Mono, Consolas") });
        Content.Children.Add(new Border { Style = St("Card"), Child = head });

        // download source picker (CDN加速链接 / ModelScope / HuggingFace)
        AddCard(Row(L10n.T("model.source"), L10n.T("model.source.help2"),
            Segmented(new[] { ("official", L10n.T("src.official")), ("modelscope", L10n.T("src.modelscope")), ("huggingface", L10n.T("src.huggingface")) },
                ModelSourceX.ToCode(src), v => { _app.SetModelSource(v); SelectTab("model"); })));

        // latency tier cards (2-col grid)
        AddGroupTitle(L10n.T("model.tier"));
        var grid = new UniformGrid { Columns = 2, Margin = new Thickness(16, 8, 16, 8) };
        foreach (var tier in TierList)
        {
            int ms = (int)tier;
            var card = ModeCard($"{ms} ms", L10n.T($"model.tier.{ms}.scene"), S.Tier == tier, tier == ModelTier.Ms960);
            card.Margin = new Thickness(0, 0, 8, 8);
            var t = tier;
            card.MouseLeftButtonUp += (_, _) => { _app.SelectTier(t); SelectTab("model"); };
            grid.Children.Add(card);
        }
        Content.Children.Add(new Border { Style = St("Card"), Child = grid });
        AddNote(L10n.T("model.tier.help"));

        // model management: per-tier download / cancel / use / delete + live progress
        StopModelTimer(); _modelRowRefreshers.Clear();
        if (_app.Models is { } mm)
        {
            AddGroupTitle(L10n.T("grp.models"));
            var rows = new List<UIElement>();
            foreach (var tier in TierList)
            {
                var (row, refresh) = BuildTierManageRow(mm, tier);
                rows.Add(row); _modelRowRefreshers.Add(refresh);
            }
            AddCard(rows.ToArray());
            StartModelTimer();
        }

        // VAD backend
        AddCard(Row(L10n.T("model.vad"), L10n.T("model.vad.help"),
            Select(new[] { ("firered", L10n.T("model.vad.firered")), ("silero", L10n.T("model.vad.silero")) },
                S.Vad == VadKind.Silero ? "silero" : "firered",
                v => _app.SetVad(v == "silero" ? VadKind.Silero : VadKind.FireRed), 170)));
        AddCard(Row(L10n.T("model.aslang"), null, MutedValue(L10n.T("model.aslang.zhen"))));
    }

    private DispatcherTimer? _modelTimer;
    private readonly List<Action> _modelRowRefreshers = new();

    private void StartModelTimer()
    {
        _modelTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(400) };
        _modelTimer.Tick += (_, _) => { foreach (var r in _modelRowRefreshers) r(); };
        _modelTimer.Start();
    }

    internal void StopModelTimer() { _modelTimer?.Stop(); _modelTimer = null; }

    private (Grid row, Action refresh) BuildTierManageRow(ModelManager mm, ModelTier tier)
    {
        int ms = (int)tier;
        var g = new Grid { Margin = new Thickness(0, 12, 0, 12) };
        g.ColumnDefinitions.Add(new ColumnDefinition());
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        var left = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        var titleRow = new StackPanel { Orientation = Orientation.Horizontal };
        titleRow.Children.Add(new TextBlock { Text = L10n.T("model.tierRow", L10n.T($"model.tier.{ms}.name")), Foreground = Br("Text"), FontSize = 13, FontWeight = FontWeights.SemiBold, VerticalAlignment = VerticalAlignment.Center });
        var badge = new Border { Style = St("Badge"), Margin = new Thickness(8, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center, Visibility = Visibility.Collapsed, Child = new TextBlock { Text = L10n.T("model.active"), Foreground = Br("AccentB"), FontSize = 10, FontWeight = FontWeights.SemiBold } };
        titleRow.Children.Add(badge);
        // quantized / full-precision tag — reflects the ACTUAL file on disk (size heuristic), shown once downloaded.
        var qText = new TextBlock { FontSize = 10, FontWeight = FontWeights.SemiBold };
        var qBadge = new Border { Style = St("Badge"), Margin = new Thickness(8, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center, Visibility = Visibility.Collapsed, Child = qText };
        titleRow.Children.Add(qBadge);
        left.Children.Add(titleRow);
        var state = new TextBlock { Style = St("RowDesc"), Margin = new Thickness(0, 3, 0, 0) };
        left.Children.Add(state);
        var track = new Border { Height = 5, CornerRadius = new CornerRadius(2.5), Background = Br("Field"), Margin = new Thickness(0, 7, 0, 0), Width = 220, HorizontalAlignment = HorizontalAlignment.Left, Visibility = Visibility.Collapsed };
        var fill = new Border { Height = 5, CornerRadius = new CornerRadius(2.5), Background = Br("AccentA"), HorizontalAlignment = HorizontalAlignment.Left, Width = 0 };
        track.Child = fill;
        left.Children.Add(track);
        Grid.SetColumn(left, 0); g.Children.Add(left);

        var btns = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center, HorizontalAlignment = HorizontalAlignment.Right };
        Grid.SetColumn(btns, 1); g.Children.Add(btns);

        string lastKey = "";
        void Refresh()
        {
            double? prog = mm.DownloadProgress(tier);
            bool downloaded = mm.IsTierDownloaded(tier);
            bool failed = mm.DidTierFail(tier);
            bool active = S.Tier == tier;
            bool bundled = downloaded && !System.IO.Directory.Exists(ModelPaths.ForTier(tier).TierDir);
            badge.Visibility = active ? Visibility.Visible : Visibility.Collapsed;

            // quantized / full-precision tag (by actual encoder size); only when present + not mid-download.
            var q = (downloaded && prog is null) ? ModelQuantized(ModelPaths.ForTier(tier)) : null;
            if (q is bool isQ)
            {
                qText.Text = L10n.T(isQ ? "model.quantized" : "model.notquantized");
                qText.Foreground = Br(isQ ? "AccentA" : "TextMuted");
                qBadge.Visibility = Visibility.Visible;
            }
            else qBadge.Visibility = Visibility.Collapsed;

            if (prog is double p)
            {
                track.Visibility = Visibility.Visible;
                fill.Width = Math.Max(0, track.ActualWidth > 0 ? track.ActualWidth * p : 220 * p);
                state.Text = L10n.T("model.downloading", (int)(p * 100));
                state.Foreground = Br("AccentB");
            }
            else
            {
                track.Visibility = Visibility.Collapsed;
                string size = ModelSourceX.IsQuantized(ModelSourceX.From(S.ModelSource)) ? "~130 MB" : "~615 MB";
                state.Text = failed ? L10n.T("model.dl.failed") : bundled ? L10n.T("model.bundled") : downloaded ? L10n.T("model.downloaded") : (L10n.T("model.notDownloaded") + " · " + size);
                state.Foreground = Br(failed ? "Danger" : downloaded ? "Success" : "TextMuted");
            }

            string key = prog is double pp ? $"dl:{(int)(pp * 100)}" : failed ? "failed" : downloaded ? $"have:{active}:{bundled}" : "missing";
            if (key != lastKey)
            {
                lastKey = key;
                btns.Children.Clear();
                if (prog is not null)
                    btns.Children.Add(TierBtn(L10n.T("cancel"), "Ghost", () => mm.CancelDownload(tier)));
                else if (failed)
                    btns.Children.Add(TierBtn(L10n.T("download"), "Solid", () => { mm.StartDownload(tier); }));
                else if (downloaded)
                {
                    if (!active) btns.Children.Add(TierBtn(L10n.T("model.use"), "Solid", () => { _app.SelectTier(tier); SelectTab("model"); }));
                    if (!bundled) { var d = TierBtn(L10n.T("delete"), "Ghost", () => mm.DeleteTier(tier)); d.Foreground = Br("Danger"); btns.Children.Add(d); }
                }
                else
                    btns.Children.Add(TierBtn(L10n.T("download"), "Solid", () => { mm.StartDownload(tier); }));
            }
        }
        Refresh();
        return (g, Refresh);
    }

    /// <summary>Heuristic: int8-quantized encoders are ~150 MB; full-precision ~560 MB. null = unknown/missing.</summary>
    private static bool? ModelQuantized(ModelPaths paths)
    {
        try
        {
            var enc = paths.Encoder;
            if (!System.IO.File.Exists(enc)) return null;
            return new System.IO.FileInfo(enc).Length < 300L * 1024 * 1024;
        }
        catch { return null; }
    }

    private Button TierBtn(string text, string style, Action onClick)
    {
        var b = new Button { Style = St(style), Content = text, Margin = new Thickness(8, 0, 0, 0) };
        b.Click += (_, _) => onClick();
        return b;
    }

    // ============================ 共享 (local share API) ============================

    private void BuildShare()
    {
        AddGroupTitle(L10n.T("share.group.title"));

        AddCard(Row(L10n.T("share.enable.title"), L10n.T("share.enable.help"),
            Toggle(S.ApiEnabled, v => { _app.SetApiEnabled(v); SelectTab("share"); })));

        if (!S.ApiEnabled) return;

        int port = _app.ApiBoundPort > 0 ? _app.ApiBoundPort : S.ApiPort;
        string baseUrl = $"http://127.0.0.1:{port}";

        // access url + LAN
        AddCard(
            Row(L10n.Loc("访问地址", "Endpoint", "アクセス先", "접속 주소"), L10n.Loc("默认仅本机可访问", "Localhost only by default", "デフォルトではこの端末のみアクセス可能", "기본적으로 이 기기에서만 접속 가능"), MonoValue(baseUrl)),
            Row(L10n.T("share.lan.title"), L10n.T("share.lan.help"), Toggle(S.ApiAllowLAN, v => { _app.SetApiAllowLAN(v); SelectTab("share"); })));

        // auth key + copy / reset (value left of buttons, on the right)
        var keyVal = new TextBlock { Text = ShortKey(_app.ApiKey), Foreground = Br("Text"), FontFamily = new FontFamily("Cascadia Mono, Consolas"), FontSize = 12, VerticalAlignment = VerticalAlignment.Center };
        var copy = new Button { Style = St("Ghost"), Content = L10n.T("share.copy"), Margin = new Thickness(10, 0, 0, 0) };
        copy.Click += (_, _) => { try { System.Windows.Clipboard.SetText(_app.ApiKey); copy.Content = L10n.T("share.copied"); } catch { } };
        var reset = new Button { Style = St("Ghost"), Content = L10n.T("share.reset"), Margin = new Thickness(8, 0, 0, 0), Foreground = Br("Danger") };
        reset.Click += (_, _) => { _app.RegenerateApiKey(); SelectTab("share"); };
        var keyRight = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right };
        keyRight.Children.Add(keyVal); keyRight.Children.Add(copy); keyRight.Children.Add(reset);
        AddCard(Row(L10n.Loc("鉴权 key", "Auth key", "認証キー", "인증 키"), L10n.Loc("每个请求都要带它;泄露后点「重置」即可作废旧 key。", "Required on every request; Reset revokes the old key.", "リクエストごとに必要です。漏えいした場合は「リセット」で旧キーを無効化できます。", "모든 요청에 필요합니다. 유출 시 「재설정」으로 기존 키를 무효화할 수 있습니다."), keyRight));

        // one-tap install into AI assistants
        AddGroupTitle(L10n.T("share.install.title"));
        var agents = new (string label, string dir)[] { ("OpenClaw", ".openclaw/skills/vibe_xasr/"), ("Claude Code", ".claude/skills/vibe_xasr/"), ("Hermes", ".hermes/skills/vibe_xasr/") };
        foreach (var (label, dir) in agents)
        {
            string cmd = L10n.Loc(
                $"请帮我安装 Vibe XASR 技能:先 `mkdir -p ~/{dir}`,再 `curl -s -H \"Authorization: Bearer {_app.ApiKey}\" \"{baseUrl}/skill\" -o ~/{dir}SKILL.md` 取得说明并保存。之后照 SKILL.md 用它读我的语音听写记录 / 词典 / 口令(只读,仅本机)。",
                $"Please install the Vibe XASR skill: `mkdir -p ~/{dir}`, then `curl -s -H \"Authorization: Bearer {_app.ApiKey}\" \"{baseUrl}/skill\" -o ~/{dir}SKILL.md`. Then use SKILL.md to read my dictation records / dictionary / snippets (read-only, local).",
                $"Vibe XASR スキルをインストールしてください:まず `mkdir -p ~/{dir}`、次に `curl -s -H \"Authorization: Bearer {_app.ApiKey}\" \"{baseUrl}/skill\" -o ~/{dir}SKILL.md` で説明を取得して保存します。その後は SKILL.md に従って、私の音声入力の記録 / 辞書 / 口令を読み取ってください(読み取り専用・この端末のみ)。",
                $"Vibe XASR 스킬을 설치해 주세요: 먼저 `mkdir -p ~/{dir}`, 그다음 `curl -s -H \"Authorization: Bearer {_app.ApiKey}\" \"{baseUrl}/skill\" -o ~/{dir}SKILL.md` 로 설명을 받아 저장합니다. 이후 SKILL.md에 따라 제 음성 받아쓰기 기록 / 사전 / 명령어를 읽어 주세요(읽기 전용, 이 기기에서만).");
            var head = new Grid();
            head.ColumnDefinitions.Add(new ColumnDefinition());
            head.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            var nameSp = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
            nameSp.Children.Add(new TextBlock { Text = label, Foreground = Br("Text"), FontSize = 13.5, FontWeight = FontWeights.SemiBold, VerticalAlignment = VerticalAlignment.Center });
            nameSp.Children.Add(new TextBlock { Text = " " + dir, Foreground = Br("TextMuted"), FontFamily = new FontFamily("Cascadia Mono, Consolas"), FontSize = 11, VerticalAlignment = VerticalAlignment.Bottom, Margin = new Thickness(8, 0, 0, 1) });
            Grid.SetColumn(nameSp, 0); head.Children.Add(nameSp);
            var copyCmd = new Button { Style = St("Ghost"), Content = L10n.T("share.copyCmd") };
            copyCmd.Click += (_, _) => { try { System.Windows.Clipboard.SetText(cmd); copyCmd.Content = L10n.T("share.copied"); } catch { } };
            Grid.SetColumn(copyCmd, 1); head.Children.Add(copyCmd);
            var body = new TextBlock { Text = cmd, Style = St("RowDesc"), FontFamily = new FontFamily("Cascadia Mono, Consolas"), FontSize = 11, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 8, 0, 0) };
            AddCardRaw(head, body);
        }
    }

    private static string ShortKey(string k) => string.IsNullOrEmpty(k) ? "" : (k.Length <= 18 ? k : k[..10] + "…" + k[^6..]);
    private TextBlock MonoValue(string text) => new() { Text = text, Foreground = Br("Text"), FontFamily = new FontFamily("Cascadia Mono, Consolas"), FontSize = 12, VerticalAlignment = VerticalAlignment.Center, HorizontalAlignment = HorizontalAlignment.Right };

    // ============================ 权限 (permissions) ============================

    private void BuildPermissions()
    {
        AddGroupTitle(L10n.T("grp.permissions"));

        bool granted = _app.MicGranted();
        // green/amber status banner
        var bannerBg = new SolidColorBrush(WithAlpha(((SolidColorBrush)Br(granted ? "Success" : "Warn")).Color, 28));
        var banner = new Border { CornerRadius = new CornerRadius(12), Background = bannerBg, Padding = new Thickness(16, 12, 16, 12), Margin = new Thickness(0, 0, 0, 10),
            Child = new TextBlock { Text = L10n.T(granted ? "perm.banner.ok" : "perm.banner.warn"), Foreground = Br(granted ? "Success" : "Warn"), FontSize = 13, FontWeight = FontWeights.SemiBold, TextWrapping = TextWrapping.Wrap } };
        Content.Children.Add(banner);

        // mic granted pill
        var micPill = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right };
        micPill.Children.Add(new Border { CornerRadius = new CornerRadius(8), Background = new SolidColorBrush(WithAlpha(((SolidColorBrush)Br(granted ? "Success" : "Warn")).Color, 36)), Padding = new Thickness(10, 4, 10, 4),
            Child = new TextBlock { Text = L10n.T(granted ? "perm.granted" : "perm.denied"), Foreground = Br(granted ? "Success" : "Warn"), FontSize = 12, FontWeight = FontWeights.SemiBold } });

        // recording device select
        var devices = _app.MicDevices();
        var opts = devices.Select(d => (d.Id, d.Name)).ToArray();
        var devSel = Select(opts.Length == 0 ? new[] { ("", L10n.Loc("系统默认麦克风", "System default mic", "システム既定のマイク", "시스템 기본 마이크")) } : opts, _app.MicDeviceId, v => _app.SetMicDevice(v), 230);

        var recheck = new Button { Style = St("Ghost"), Content = L10n.T("perm.recheck"), HorizontalAlignment = HorizontalAlignment.Right };
        recheck.Click += (_, _) => SelectTab("permissions");

        AddCard(
            Row(L10n.T("perm.mic"), L10n.T("perm.mic.help"), micPill),
            Row(L10n.Loc("录音设备", "Recording device", "録音デバイス", "녹음 장치"), L10n.Loc("选择用哪个麦克风录音(默认跟随系统)。", "Pick the mic to record with.", "録音に使うマイクを選択します(既定はシステムに従います)。", "녹음에 사용할 마이크를 선택합니다(기본값은 시스템 설정)."), devSel),
            Row(L10n.T("perm.input"), L10n.T("perm.input.help"), MutedValue("ⓘ")),
            Row("", null, recheck));
    }

    // ============================ AI 润色 (cloud LLM) ============================
    // Full macOS CloudLLMTab parity (local-llama section intentionally omitted on Windows).

    private bool _cloudShowKey;
    private (bool done, bool ok, int ping, string add, string msg) _cloudTest;
    private List<CloudTemplate> _cloudTemplates = new();
    private List<CloudCustomProvider> _cloudCustoms = new();
    private List<CloudProfile> _cloudProfiles = new();

    private void BuildCloud()
    {
        _cloudTemplates = CloudJson.Templates(S.CloudTemplatesJson);
        _cloudCustoms = CloudJson.CustomProviders(S.CloudCustomProvidersJson);
        _cloudProfiles = CloudJson.Profiles(S.CloudProfilesJson);
        CloudRequestLog.Shared.Enabled = S.CloudLogEnabled;

        AddGroupTitle(L10n.Loc("云端大模型", "Cloud LLM", "クラウド LLM", "클라우드 LLM"));
        BuildCloudConfigCard();

        if (!S.CloudEnabled) return;

        AddGroupTitle(L10n.Loc("最近请求 · 排查", "Recent requests · debug", "最近のリクエスト · デバッグ", "최근 요청 · 디버그"));
        BuildCloudLogCard();
        AddGroupTitle(L10n.Loc("润色处理项 · 自动拼成 Prompt", "Processing · builds the auto prompt", "整形処理 · 自動でプロンプトを生成", "정리 항목 · 자동 프롬프트 생성"));
        AddCard(
            Row(L10n.Loc("数字规整", "Numbers → digits", "数字の整形", "숫자 정규화"), L10n.Loc("一百二十三 → 123、三点半 → 3:30、百分之二十 → 20%。成语、计数词不动。", "Spoken numerals → digits.", "「一百二十三」→ 123、「三点半」→ 3:30、「百分之二十」→ 20%。慣用句・助数詞はそのまま。", "「一百二十三」→ 123, 「三点半」→ 3:30, 「百分之二十」→ 20%. 관용구·수량사는 유지."), Toggle(S.CloudNumbers, v => { S.CloudNumbers = v; _app.ApplyCloudSettings(); })),
            Row(L10n.Loc("去口水词", "Remove fillers", "言いよどみ除去", "군더더기 제거"), L10n.Loc("去掉「嗯 / 呃 / 唉」和口吃重复(那个那个 → 那个)。叠词保留。", "Strip fillers + stutters.", "「えー / あの / うー」やどもりの重複(あのあの → あの)を除去。畳語は保持。", "「음 / 어 / 에」와 말더듬 반복(저기저기 → 저기)을 제거. 첩어는 유지."), Toggle(S.CloudFillers, v => { S.CloudFillers = v; _app.ApplyCloudSettings(); })),
            Row(L10n.Loc("改口纠正", "Keep restatement", "言い直しの修正", "정정 반영"), L10n.Loc("说话中途自我更正时,只保留最终说法,删掉被改掉的前半句。", "Keep only the final wording on self-correction.", "話の途中で言い直したとき、最終的な表現だけを残し、訂正前の部分を削除します。", "말하는 도중 정정한 경우 최종 표현만 남기고 정정된 앞부분을 삭제합니다."), Toggle(S.CloudRestate, v => { S.CloudRestate = v; _app.ApplyCloudSettings(); })),
            Row(L10n.Loc("热词修正", "Apply hotwords", "ホットワード修正", "핫워드 보정"), L10n.Loc("参照「词典」里的专有名词与术语,修正同音 / 近音误写。", "Fix homophones using the 词典 hotword list.", "「辞書」の固有名詞・専門用語を参照し、同音・類音の誤りを修正します。", "「사전」의 고유명사·전문 용어를 참조하여 동음·유음 오기를 보정합니다."), Toggle(S.CloudHotwords, v => { S.CloudHotwords = v; _app.ApplyCloudSettings(); })));
        AddGroupTitle(L10n.Loc("提示词模板", "Prompt templates", "プロンプトテンプレート", "프롬프트 템플릿"));
        BuildCloudPromptCard();

        // local LLM — not supported on Windows: shown greyed/disabled (macOS parity, Win-disabled)
        AddGroupTitle(L10n.Loc("本地大模型", "Local LLM", "ローカル LLM", "로컬 LLM"));
        BuildCloudLocalCard();
    }

    private void BuildCloudLocalCard()
    {
        var sp = new StackPanel { Margin = new Thickness(18, 12, 18, 14) };
        var head = new Grid();
        head.ColumnDefinitions.Add(new ColumnDefinition());
        head.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var titleRow = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
        titleRow.Children.Add(new TextBlock { Text = L10n.T("cloud.local.title"), Foreground = Br("TextMuted"), FontSize = 14, FontWeight = FontWeights.SemiBold, VerticalAlignment = VerticalAlignment.Center });
        titleRow.Children.Add(new Border { Style = St("Badge"), Margin = new Thickness(8, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center, Child = new TextBlock { Text = "Beta", Foreground = Br("AccentA"), FontSize = 10, FontWeight = FontWeights.SemiBold } });
        Grid.SetColumn(titleRow, 0); head.Children.Add(titleRow);
        var tog = new ToggleButton { Style = St("Toggle"), IsChecked = false, IsEnabled = false, HorizontalAlignment = HorizontalAlignment.Right };
        Grid.SetColumn(tog, 1); head.Children.Add(tog);
        sp.Children.Add(head);
        sp.Children.Add(new TextBlock { Text = L10n.T("cloud.local.desc"), Style = St("RowDesc"), Margin = new Thickness(0, 6, 0, 0), TextWrapping = TextWrapping.Wrap });
        sp.Children.Add(new TextBlock { Text = "🚫 " + L10n.T("cloud.local.win"), Foreground = Br("Warn"), FontSize = 11.5, Margin = new Thickness(0, 6, 0, 0), TextWrapping = TextWrapping.Wrap });
        Content.Children.Add(new Border { Style = St("Card"), Child = sp });
    }

    private void CloudCommit()
    {
        S.CloudTemplatesJson = CloudJson.Encode(_cloudTemplates);
        S.CloudCustomProvidersJson = CloudJson.Encode(_cloudCustoms);
        S.CloudProfilesJson = CloudJson.Encode(_cloudProfiles);
        _app.ApplyCloudSettings();
    }

    private string CloudProviderLabel(string key)
    {
        if (LlmProviders.IsBuiltin(key)) return LlmProviders.LocalizedLabel(key, Zh);
        return _cloudCustoms.FirstOrDefault(c => c.Id == key)?.Label ?? (string.IsNullOrEmpty(key) ? "自定义" : key);
    }

    private void BuildCloudConfigCard()
    {
        var sp = new StackPanel { Margin = new Thickness(18, 12, 18, 14) };

        // header: title + 推荐 badge + enable toggle
        var head = new Grid();
        head.ColumnDefinitions.Add(new ColumnDefinition());
        head.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var titleRow = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
        titleRow.Children.Add(new TextBlock { Text = L10n.Loc("调用云端大模型", "Use a cloud LLM", "クラウド LLM を利用", "클라우드 LLM 사용"), Foreground = Br("Text"), FontSize = 15, FontWeight = FontWeights.SemiBold, VerticalAlignment = VerticalAlignment.Center });
        titleRow.Children.Add(new Border { Style = St("Badge"), Margin = new Thickness(8, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center, Child = new TextBlock { Text = L10n.T("badge.recommended"), Foreground = Br("AccentA"), FontSize = 10, FontWeight = FontWeights.SemiBold } });
        Grid.SetColumn(titleRow, 0); head.Children.Add(titleRow);
        var enToggle = Toggle(S.CloudEnabled, v => { S.CloudEnabled = v; if (v && S.Mode != DictationMode.Paste) _app.SetMode(DictationMode.Paste); _app.ApplyCloudSettings(); SelectTab("cloud"); });
        Grid.SetColumn(enToggle, 1); head.Children.Add(enToggle);
        sp.Children.Add(head);
        sp.Children.Add(new TextBlock { Text = L10n.Loc("润色质量更高、速度更快,需联网并消耗服务商额度。API Key 仅加密存储在本机,不会上传。", "Higher quality + faster; needs the internet and uses your provider quota. The API key is encrypted on this machine only, never uploaded.", "整形品質が高く高速ですが、ネット接続とプロバイダーの利用枠を消費します。API キーはこの端末に暗号化して保存され、送信されません。", "정리 품질이 높고 빠르지만 인터넷 연결과 제공업체 사용량이 필요합니다. API 키는 이 기기에만 암호화 저장되며 업로드되지 않습니다."), Style = St("RowDesc"), Margin = new Thickness(0, 6, 0, 0), TextWrapping = TextWrapping.Wrap });

        if (S.CloudEnabled)
        {
            // profiles bar
            sp.Children.Add(CloudProfilesBar());

            var prov = LlmProviders.Find(S.CloudProvider);
            // provider + model (two columns)
            var provOpts = LlmProviders.All.Select(p => (p.Key, (LlmProviders.IsBuiltin(p.Key) ? p.Mark + "  " : "") + LlmProviders.LocalizedLabel(p.Key, Zh)))
                .Concat(_cloudCustoms.Select(c => (c.Id, "•  " + c.Label))).ToArray();
            var provSel = Select(provOpts, S.CloudProvider, OnProviderChanged, 240); provSel.HorizontalAlignment = HorizontalAlignment.Stretch; provSel.Width = double.NaN;

            FrameworkElement modelCtl;
            if (prov.Models.Length > 0)
            {
                var mopts = prov.Models.Select(m => (m.Id, m.Label)).ToArray();
                var ms = Select(mopts, S.CloudModel, v => { S.CloudModel = v; _cloudTest = default; _app.ApplyCloudSettings(); }, 240);
                ms.HorizontalAlignment = HorizontalAlignment.Stretch; ms.Width = double.NaN; modelCtl = ms;
            }
            else modelCtl = MonoField(S.CloudModel, t => { S.CloudModel = t; _cloudTest = default; _app.ApplyCloudSettings(); });
            sp.Children.Add(TwoCol(L10n.Loc("服务商", "Provider", "プロバイダー", "제공업체"), provSel, prov.ModelLabel, modelCtl));

            // base url
            sp.Children.Add(Label(L10n.Loc("API 地址(Base URL)", "API base URL", "API アドレス(Base URL)", "API 주소(Base URL)")));
            sp.Children.Add(MonoField(S.CloudBaseURL, t => { S.CloudBaseURL = t; _cloudTest = default; _app.ApplyCloudSettings(); }, prov.BaseUrl));

            // api key + show
            sp.Children.Add(Label("API Key"));
            var keyGrid = new Grid();
            keyGrid.ColumnDefinitions.Add(new ColumnDefinition());
            keyGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            var keyBox = new TextBox { Style = St("FieldBox"), FontFamily = new FontFamily("Cascadia Mono, Consolas"), FontSize = 12, IsReadOnly = !_cloudShowKey, Text = _cloudShowKey ? S.CloudApiKey : MaskKey(S.CloudApiKey) };
            keyBox.LostFocus += (_, _) => { if (_cloudShowKey) { S.CloudApiKey = keyBox.Text.Trim(); _cloudTest = default; _app.ApplyCloudSettings(); } };
            Grid.SetColumn(keyBox, 0); keyGrid.Children.Add(keyBox);
            var showBtn = new Button { Style = St("Ghost"), Content = _cloudShowKey ? L10n.Loc("隐藏", "Hide", "非表示", "숨기기") : L10n.Loc("显示", "Show", "表示", "표시"), Margin = new Thickness(8, 0, 0, 0) };
            showBtn.Click += (_, _) => { if (_cloudShowKey) { S.CloudApiKey = keyBox.Text.Trim(); _app.ApplyCloudSettings(); } _cloudShowKey = !_cloudShowKey; SelectTab("cloud"); };
            Grid.SetColumn(showBtn, 1); keyGrid.Children.Add(showBtn);
            sp.Children.Add(keyGrid);

            // temperature + max tokens
            var tempBox = MonoField(S.CloudTemperature.ToString("0.##"), t => { if (double.TryParse(t, out var v)) { S.CloudTemperature = Math.Min(2, Math.Max(0, v)); _app.ApplyCloudSettings(); } });
            var maxBox = MonoField(S.CloudMaxTokens.ToString(), t => { if (int.TryParse(t, out var n)) { S.CloudMaxTokens = Math.Max(1, n); _app.ApplyCloudSettings(); } });
            sp.Children.Add(TwoCol(L10n.Loc("Temperature(0~1,润色建议 0.3)", "Temperature (0–1)", "Temperature(0〜1、整形は 0.3 推奨)", "Temperature(0~1, 정리는 0.3 권장)"), tempBox, L10n.Loc("Max Tokens(最大输出长度)", "Max tokens", "Max Tokens(最大出力長)", "Max Tokens(최대 출력 길이)"), maxBox));

            // test connection + status
            var testBtn = new Button { Style = St("Solid"), Content = L10n.Loc("测试连接与延迟", "Test connection", "接続と遅延をテスト", "연결 및 지연 테스트"), HorizontalAlignment = HorizontalAlignment.Left, Margin = new Thickness(0, 12, 0, 0) };
            var testMsg = new TextBlock { Style = St("RowDesc"), VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(12, 12, 0, 0) };
            void SetMsg() { if (_cloudTest.done) { testMsg.Text = _cloudTest.ok ? L10n.Loc($"● 连接正常 · 单次往返 {_cloudTest.ping}ms · 整段润色约 {_cloudTest.add}", $"● OK · {_cloudTest.ping}ms RTT", $"● 接続正常 · 往復 {_cloudTest.ping}ms · 全文整形 約 {_cloudTest.add}", $"● 연결 정상 · 왕복 {_cloudTest.ping}ms · 전체 정리 약 {_cloudTest.add}") : L10n.Loc($"● 测试失败 · {_cloudTest.msg}", $"● Failed · {_cloudTest.msg}", $"● テスト失敗 · {_cloudTest.msg}", $"● 테스트 실패 · {_cloudTest.msg}"); testMsg.Foreground = Br(_cloudTest.ok ? "Success" : "Warn"); } else { testMsg.Text = L10n.Loc("会发送一次极短请求,测量真实往返延迟。", "Sends one tiny request to measure latency.", "ごく短いリクエストを 1 回送信し、実際の往復遅延を測定します。", "아주 짧은 요청을 한 번 보내 실제 왕복 지연을 측정합니다."); testMsg.Foreground = Br("TextMuted"); } }
            SetMsg();
            testBtn.Click += async (_, _) =>
            {
                testBtn.IsEnabled = false; testMsg.Text = L10n.Loc("测试中…", "Testing…", "テスト中…", "테스트 중…"); testMsg.Foreground = Br("TextMuted");
                var r = await CloudRefiner.TestConnectionAsync(S.CloudBaseURL, S.CloudModel, S.CloudApiKey);
                _cloudTest = (true, r.ok, r.ping, r.add, r.msg); testBtn.IsEnabled = true; SetMsg();
            };
            var testRow = new StackPanel { Orientation = Orientation.Horizontal };
            testRow.Children.Add(testBtn); testRow.Children.Add(testMsg);
            sp.Children.Add(testRow);

            if (!string.IsNullOrEmpty(prov.Price))
                sp.Children.Add(new TextBlock { Text = "💳 " + prov.Price, Style = St("RowDesc"), Margin = new Thickness(0, 12, 0, 0) });
        }

        Content.Children.Add(new Border { Style = St("Card"), Child = sp });
    }

    private FrameworkElement CloudProfilesBar()
    {
        var host = new StackPanel { Margin = new Thickness(0, 16, 0, 2) };
        host.Children.Add(new TextBlock { Text = L10n.Loc("我的配置 · 保存当前设置,一键切换(点选套用)", "My profiles · save + one-tap switch", "マイ設定 · 現在の設定を保存し、ワンタップで切替(クリックで適用)", "내 설정 · 현재 설정 저장, 한 번에 전환(클릭하여 적용)"), Style = St("RowDesc"), Margin = new Thickness(0, 0, 0, 6) });
        var wrap = new WrapPanel();
        foreach (var p in _cloudProfiles)
        {
            var pid = p.Id;
            var chipSp = new StackPanel { Orientation = Orientation.Horizontal };
            chipSp.Children.Add(new TextBlock { Text = $"{p.Name} · {CloudProviderLabel(p.Provider)}", Foreground = Br("Text"), FontSize = 12, VerticalAlignment = VerticalAlignment.Center });
            var x = new TextBlock { Text = "✕", Foreground = Br("TextMuted"), FontSize = 11, Margin = new Thickness(8, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center, Cursor = Cursors.Hand };
            x.MouseLeftButtonUp += (_, e) => { e.Handled = true; _cloudProfiles.RemoveAll(z => z.Id == pid); CloudCommit(); SelectTab("cloud"); };
            chipSp.Children.Add(x);
            var chip = new Border { CornerRadius = new CornerRadius(8), Background = Br("Field"), Padding = new Thickness(11, 6, 11, 6), Margin = new Thickness(0, 0, 8, 8), Cursor = Cursors.Hand, Child = chipSp };
            chip.MouseLeftButtonUp += (_, _) => { var prof = _cloudProfiles.FirstOrDefault(z => z.Id == pid); if (prof is not null) CloudLoadProfile(prof); };
            wrap.Children.Add(chip);
        }
        var save = new Border { CornerRadius = new CornerRadius(8), BorderBrush = Br("Hairline"), BorderThickness = new Thickness(1), Padding = new Thickness(11, 6, 11, 6), Margin = new Thickness(0, 0, 8, 8), Cursor = Cursors.Hand, Child = new TextBlock { Text = L10n.Loc("＋ 保存当前为配置", "＋ Save current", "＋ 現在の設定を保存", "＋ 현재 설정 저장"), Foreground = Br("AccentA"), FontSize = 12 } };
        save.MouseLeftButtonUp += (_, _) =>
        {
            int n = _cloudProfiles.Count + 1; var id = $"prof{n}";
            while (_cloudProfiles.Any(z => z.Id == id)) { n++; id = $"prof{n}"; }
            _cloudProfiles.Add(new CloudProfile { Id = id, Name = L10n.Loc("配置", "Profile", "設定", "설정") + n, Provider = S.CloudProvider, BaseURL = S.CloudBaseURL, Model = S.CloudModel, Temperature = S.CloudTemperature, MaxTokens = S.CloudMaxTokens, Numbers = S.CloudNumbers, Fillers = S.CloudFillers, Restate = S.CloudRestate, Hotwords = S.CloudHotwords, ActiveTemplate = S.CloudActiveTemplate, AutoOverride = S.CloudAutoOverride });
            try { SecretStore.Set("cloud_profile_" + id, S.CloudApiKey); } catch { }
            CloudCommit(); SelectTab("cloud");
        };
        wrap.Children.Add(save);
        host.Children.Add(wrap);
        return host;
    }

    private void CloudLoadProfile(CloudProfile p)
    {
        S.CloudProvider = p.Provider; S.CloudBaseURL = p.BaseURL; S.CloudModel = p.Model;
        S.CloudTemperature = p.Temperature; S.CloudMaxTokens = p.MaxTokens;
        S.CloudNumbers = p.Numbers; S.CloudFillers = p.Fillers; S.CloudRestate = p.Restate; S.CloudHotwords = p.Hotwords;
        S.CloudActiveTemplate = p.ActiveTemplate; S.CloudAutoOverride = p.AutoOverride;
        try { var k = SecretStore.Get("cloud_profile_" + p.Id); if (!string.IsNullOrEmpty(k)) S.CloudApiKey = k; } catch { }
        _cloudTest = default; CloudCommit(); SelectTab("cloud");
    }

    private void OnProviderChanged(string key)
    {
        if (key == S.CloudProvider) return;
        try { SecretStore.Set("cloud_profile_" + S.CloudProvider, S.CloudApiKey); } catch { }
        S.CloudProvider = key;
        if (LlmProviders.IsBuiltin(key)) { var p = LlmProviders.Find(key); S.CloudBaseURL = p.BaseUrl; S.CloudModel = string.IsNullOrEmpty(p.DefaultModel) ? (p.Models.FirstOrDefault()?.Id ?? "") : p.DefaultModel; }
        else { var c = _cloudCustoms.FirstOrDefault(z => z.Id == key); if (c is not null) S.CloudBaseURL = c.BaseURL; }
        try { var k = SecretStore.Get("cloud_profile_" + key); if (!string.IsNullOrEmpty(k)) S.CloudApiKey = k; } catch { }
        _cloudTest = default; _app.ApplyCloudSettings(); SelectTab("cloud");
    }

    private void BuildCloudLogCard()
    {
        var sp = new StackPanel { Margin = new Thickness(18, 14, 18, 14) };
        var head = new Grid();
        head.ColumnDefinitions.Add(new ColumnDefinition());
        head.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        head.Children.Add(new TextBlock { Text = L10n.Loc("记录每次云端调用,便于排查 / 提 issue · 最近 20 条", "Logs each cloud call · last 20", "クラウド呼び出しを記録 · デバッグ / issue 報告に · 直近 20 件", "클라우드 호출 기록 · 디버그 / 이슈 제보용 · 최근 20건"), Style = St("RowDesc"), VerticalAlignment = VerticalAlignment.Center });
        var right = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Center };
        if (S.CloudLogEnabled)
        {
            var clear = new TextBlock { Text = L10n.Loc("清空", "Clear", "クリア", "비우기"), Foreground = Br("TextMuted"), FontSize = 12, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 12, 0), Cursor = Cursors.Hand };
            clear.MouseLeftButtonUp += (_, _) => { CloudRequestLog.Shared.Clear(); SelectTab("cloud"); };
            right.Children.Add(clear);
        }
        right.Children.Add(new TextBlock { Text = L10n.Loc("记录", "Log", "記録", "기록"), Foreground = Br("TextMuted"), FontSize = 12, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 8, 0) });
        right.Children.Add(Toggle(S.CloudLogEnabled, v => { S.CloudLogEnabled = v; _app.ApplyCloudSettings(); SelectTab("cloud"); }));
        Grid.SetColumn(right, 1); head.Children.Add(right);
        sp.Children.Add(head);

        var entries = CloudRequestLog.Shared.Snapshot().Take(8).ToList();
        if (!S.CloudLogEnabled)
            sp.Children.Add(new TextBlock { Text = L10n.Loc("「记录请求」已关闭。打开后保存最近 20 条(输入→输出),用于排查或提 issue。", "Logging is off.", "「リクエスト記録」はオフです。オンにすると直近 20 件(入力→出力)を保存し、デバッグや issue 報告に使えます。", "「요청 기록」이 꺼져 있습니다. 켜면 최근 20건(입력→출력)을 저장하여 디버그나 이슈 제보에 사용할 수 있습니다."), Style = St("RowDesc"), Margin = new Thickness(0, 10, 0, 0), TextWrapping = TextWrapping.Wrap });
        else if (entries.Count == 0)
            sp.Children.Add(new TextBlock { Text = L10n.Loc("还没有记录。说一段话(≥6 字),这里会列出每次云端请求。", "No requests yet.", "まだ記録がありません。6 文字以上話すと、ここに各クラウドリクエストが一覧表示されます。", "아직 기록이 없습니다. 6자 이상 말하면 각 클라우드 요청이 여기에 표시됩니다."), Style = St("RowDesc"), Margin = new Thickness(0, 10, 0, 0), TextWrapping = TextWrapping.Wrap });
        else
            foreach (var e in entries)
            {
                if (sp.Children.Count > 1) sp.Children.Add(new Border { Height = 1, Background = Br("Hairline"), Margin = new Thickness(0, 8, 0, 8) });
                var row = new StackPanel { Margin = new Thickness(0, 8, 0, 0) };
                var top = new StackPanel { Orientation = Orientation.Horizontal };
                top.Children.Add(new Ellipse { Width = 8, Height = 8, Fill = Br(CloudLogBrush(e.Status)), VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 8, 0) });
                top.Children.Add(new TextBlock { Text = $"{e.At:HH:mm:ss}  {CloudProviderLabel(e.Provider)} · {e.Model}", Foreground = Br("Text"), FontSize = 12, VerticalAlignment = VerticalAlignment.Center });
                top.Children.Add(new TextBlock { Text = $"   {e.Ms}ms  {CloudLogText(e.Status)}", Foreground = Br(CloudLogBrush(e.Status)), FontFamily = new FontFamily("Cascadia Mono, Consolas"), FontSize = 11, VerticalAlignment = VerticalAlignment.Center });
                row.Children.Add(top);
                string change = e.Status != "ok" ? $"「{Clip(e.Input, 40)}」 · {CloudLogText(e.Status)}"
                              : e.Input.Trim() == e.Output.Trim() ? $"「{Clip(e.Input, 60)}」 · {L10n.Loc("无修改", "no change", "変更なし", "변경 없음")}"
                              : L10n.Loc($"从「{Clip(e.Input, 30)}」改成「{Clip(e.Output, 30)}」", $"{Clip(e.Input, 30)} → {Clip(e.Output, 30)}", $"「{Clip(e.Input, 30)}」→「{Clip(e.Output, 30)}」", $"「{Clip(e.Input, 30)}」→「{Clip(e.Output, 30)}」");
                row.Children.Add(new TextBlock { Text = change, Style = St("RowDesc"), Margin = new Thickness(16, 2, 0, 0), TextWrapping = TextWrapping.Wrap });
                sp.Children.Add(row);
            }
        Content.Children.Add(new Border { Style = St("Card"), Child = sp });
    }

    private void BuildCloudPromptCard()
    {
        var sp = new StackPanel { Margin = new Thickness(18, 14, 18, 14) };

        // template chips
        var chips = new WrapPanel();
        chips.Children.Add(TemplateChip("⚡ " + L10n.Loc("自动", "Auto", "自動", "자동"), S.CloudActiveTemplate == "auto", () => { S.CloudActiveTemplate = "auto"; _app.ApplyCloudSettings(); RebuildCurrent(); }, null));
        foreach (var t in _cloudTemplates)
        {
            var tid = t.Id;
            chips.Children.Add(TemplateChip(t.Name, S.CloudActiveTemplate == tid,
                () => { S.CloudActiveTemplate = tid; _app.ApplyCloudSettings(); RebuildCurrent(); },
                () => { _cloudTemplates.RemoveAll(x => x.Id == tid); if (S.CloudActiveTemplate == tid) S.CloudActiveTemplate = "auto"; CloudCommit(); RebuildCurrent(); }));
        }
        var add = new Border { CornerRadius = new CornerRadius(8), BorderBrush = Br("Hairline"), BorderThickness = new Thickness(1), Padding = new Thickness(11, 6, 11, 6), Margin = new Thickness(0, 0, 8, 8), Cursor = Cursors.Hand, Child = new TextBlock { Text = L10n.Loc("＋ 新建模板", "＋ New", "＋ 新規テンプレート", "＋ 새 템플릿"), Foreground = Br("AccentA"), FontSize = 12 } };
        add.MouseLeftButtonUp += (_, _) => { int n = _cloudTemplates.Count + 1; var id = $"t{n}-{_cloudTemplates.Count}"; _cloudTemplates.Add(new CloudTemplate { Id = id, Name = L10n.Loc("模板", "Tpl", "テンプレート", "템플릿") + n, Content = CloudCurrentPrompt() }); S.CloudActiveTemplate = id; CloudCommit(); RebuildCurrent(); };
        chips.Children.Add(add);
        // open the standalone Prompt Studio window (macOS build 204 parity)
        var openWin = new Border { CornerRadius = new CornerRadius(8), BorderBrush = Br("Hairline"), BorderThickness = new Thickness(1, 1, 1, 1), Padding = new Thickness(11, 6, 11, 6), Margin = new Thickness(0, 0, 8, 8), Cursor = Cursors.Hand, Child = new TextBlock { Text = "⧉ " + L10n.T("studio.open"), Foreground = Br("AccentB"), FontSize = 12 } };
        openWin.MouseLeftButtonUp += (_, _) => _app.OpenPromptStudio();
        chips.Children.Add(openWin);
        sp.Children.Add(chips);

        // editor (declare first so token chips can reference it)
        var editor = new TextBox { Style = St("FieldBox"), Text = CloudCurrentPrompt(), AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, Height = 172, VerticalContentAlignment = VerticalAlignment.Top, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, FontFamily = new FontFamily("Cascadia Mono, Consolas"), FontSize = 12, Margin = new Thickness(0, 4, 0, 4) };

        // placeholder token chips
        var tokRow = new WrapPanel { Margin = new Thickness(0, 6, 0, 6) };
        tokRow.Children.Add(new TextBlock { Text = L10n.Loc("插入占位符", "Insert token", "プレースホルダーを挿入", "자리표시자 삽입"), Style = St("RowDesc"), VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 10, 0) });
        foreach (var (token, _) in CloudSeeds.Tokens)
        {
            var tok = token;
            var chip = new Border { CornerRadius = new CornerRadius(6), Background = Br("AccentSoft"), Padding = new Thickness(8, 3, 8, 3), Margin = new Thickness(0, 0, 8, 6), Cursor = Cursors.Hand, Child = new TextBlock { Text = token, Foreground = Br("AccentA"), FontFamily = new FontFamily("Cascadia Mono, Consolas"), FontSize = 11 } };
            chip.MouseLeftButtonUp += (_, _) => { int p = editor.SelectionStart; editor.Text = editor.Text.Insert(p, tok); editor.SelectionStart = p + tok.Length; editor.Focus(); };
            tokRow.Children.Add(chip);
        }
        sp.Children.Add(tokRow);

        editor.LostFocus += (_, _) => { var v = editor.Text; if (S.CloudActiveTemplate == "auto") S.CloudAutoOverride = v; else { var t = _cloudTemplates.FirstOrDefault(x => x.Id == S.CloudActiveTemplate); if (t is not null) t.Content = v; } CloudCommit(); };
        sp.Children.Add(editor);
        sp.Children.Add(new TextBlock { Text = L10n.Loc("「自动」由上方开关实时拼成;改后可恢复自动。模板可增删、点选即套用。占位符调用时自动替换(热词取自「词典」)。", "“Auto” is built from the toggles above. Tokens are filled at call time.", "「自動」は上のスイッチからリアルタイムに生成されます。編集後も自動に戻せます。テンプレートは追加・削除でき、クリックで適用。プレースホルダーは呼び出し時に自動置換されます(ホットワードは「辞書」から取得)。", "「자동」은 위 스위치로 실시간 생성됩니다. 수정 후 자동으로 되돌릴 수 있습니다. 템플릿은 추가·삭제할 수 있고 클릭하면 적용됩니다. 자리표시자는 호출 시 자동 치환됩니다(핫워드는 「사전」에서 가져옴)."), Style = St("RowDesc"), Margin = new Thickness(0, 6, 0, 0), TextWrapping = TextWrapping.Wrap });

        Content.Children.Add(new Border { Style = St("Card"), Child = sp });
    }

    private string CloudCurrentPrompt()
    {
        if (S.CloudActiveTemplate == "auto")
            return string.IsNullOrEmpty(S.CloudAutoOverride) ? CloudPrompt.BuildAuto(S.CloudNumbers, S.CloudFillers, S.CloudRestate, S.CloudHotwords) : S.CloudAutoOverride;
        return _cloudTemplates.FirstOrDefault(t => t.Id == S.CloudActiveTemplate)?.Content ?? "";
    }

    private Border TemplateChip(string name, bool active, Action onClick, Action? onDelete)
    {
        var inner = new StackPanel { Orientation = Orientation.Horizontal };
        inner.Children.Add(new TextBlock { Text = name, Foreground = active ? Br("Text") : Br("Text"), FontSize = 12, FontWeight = active ? FontWeights.SemiBold : FontWeights.Normal, VerticalAlignment = VerticalAlignment.Center });
        if (onDelete is not null)
        {
            var x = new TextBlock { Text = "✕", Foreground = Br("TextMuted"), FontSize = 11, Margin = new Thickness(8, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center, Cursor = Cursors.Hand };
            x.MouseLeftButtonUp += (_, e) => { e.Handled = true; onDelete(); };
            inner.Children.Add(x);
        }
        var chip = new Border { CornerRadius = new CornerRadius(8), Background = active ? Br("AccentSoft") : Br("Field"), BorderBrush = active ? Br("AccentA") : System.Windows.Media.Brushes.Transparent, BorderThickness = new Thickness(active ? 1.2 : 0), Padding = new Thickness(11, 6, 11, 6), Margin = new Thickness(0, 0, 8, 8), Cursor = Cursors.Hand, Child = inner };
        chip.MouseLeftButtonUp += (_, _) => onClick();
        return chip;
    }

    private static string Clip(string s, int n) { s = (s ?? "").Replace("\n", " ").Trim(); return s.Length > n ? s.Substring(0, n) + "…" : s; }
    private string CloudLogBrush(string s) => s == "ok" ? "Success" : (s is "timeout" or "skipped" ? "Warn" : "Danger");
    private string CloudLogText(string s) => s switch { "ok" => L10n.Loc("成功", "ok", "成功", "성공"), "timeout" => L10n.Loc("超时", "timeout", "タイムアウト", "시간 초과"), "skipped" => L10n.Loc("超 token", "skipped", "トークン超過", "토큰 초과"), _ => L10n.Loc("失败", "error", "失敗", "실패") };

    private TextBox MonoField(string text, Action<string> onCommit, string? placeholder = null)
    {
        var t = new TextBox { Style = St("FieldBox"), Text = text, FontFamily = new FontFamily("Cascadia Mono, Consolas"), FontSize = 12 };
        t.LostFocus += (_, _) => onCommit(t.Text.Trim());
        return t;
    }

    private Grid TwoCol(string leftLabel, FrameworkElement leftCtl, string rightLabel, FrameworkElement rightCtl)
    {
        var g = new Grid { Margin = new Thickness(0, 4, 0, 0) };
        g.ColumnDefinitions.Add(new ColumnDefinition());
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(14) });
        g.ColumnDefinitions.Add(new ColumnDefinition());
        var left = new StackPanel(); left.Children.Add(Label(leftLabel)); left.Children.Add(leftCtl);
        var right = new StackPanel(); right.Children.Add(Label(rightLabel)); right.Children.Add(rightCtl);
        Grid.SetColumn(left, 0); Grid.SetColumn(right, 2); g.Children.Add(left); g.Children.Add(right);
        return g;
    }

    // ============================ extra helpers ============================

    private static string MaskKey(string key) => string.IsNullOrEmpty(key) ? "" : new string('•', Math.Min(key.Length, 32));
    private static System.Windows.Media.Color WithAlpha(System.Windows.Media.Color c, byte a) => System.Windows.Media.Color.FromArgb(a, c.R, c.G, c.B);

    private TextBlock Label(string text) => new() { Text = text, Style = St("RowDesc"), Margin = new Thickness(2, 6, 0, 4) };

    private void AddNote(string text) =>
        Content.Children.Add(new TextBlock { Text = text, Style = St("RowDesc"), Margin = new Thickness(18, 0, 18, 10), TextWrapping = TextWrapping.Wrap });

    private void AddCardRaw(params UIElement[] children)
    {
        var sp = new StackPanel { Margin = new Thickness(18, 10, 18, 12) };
        foreach (var c in children) sp.Children.Add(c);
        Content.Children.Add(new Border { Style = St("Card"), Child = sp });
    }

    private Grid RowInline(string title, FrameworkElement control)
    {
        var g = new Grid { Margin = new Thickness(0, 10, 0, 2) };
        g.ColumnDefinitions.Add(new ColumnDefinition());
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var tb = new TextBlock { Text = title, Style = St("RowTitle"), VerticalAlignment = VerticalAlignment.Center };
        Grid.SetColumn(tb, 0); g.Children.Add(tb);
        control.VerticalAlignment = VerticalAlignment.Center;
        Grid.SetColumn(control, 1); g.Children.Add(control);
        return g;
    }

    private StackPanel RightButton(Button b)
    {
        b.HorizontalAlignment = HorizontalAlignment.Right;
        return new StackPanel { Margin = new Thickness(0, 6, 0, 0), Children = { b } };
    }

    private TextBlock MutedValue(string text) =>
        new() { Text = text, Foreground = Br("TextMuted"), FontSize = 12.5, VerticalAlignment = VerticalAlignment.Center, HorizontalAlignment = HorizontalAlignment.Right };

    private TextBox Multiline(string text, double height, Action<string> onCommit)
    {
        var t = new TextBox
        {
            Style = St("FieldBox"), Text = text, AcceptsReturn = true, TextWrapping = TextWrapping.Wrap,
            Height = height, VerticalContentAlignment = VerticalAlignment.Top,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            FontFamily = new FontFamily("Cascadia Mono, Consolas"), FontSize = 12.5,
            Margin = new Thickness(0, 0, 0, 4),
        };
        t.LostFocus += (_, _) => onCommit(t.Text);
        return t;
    }
}
