using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Linq;
using System.Windows.Forms;
using VibeXASR.Windows.Refine;
using VibeXASR.Windows.Storage;

namespace VibeXASR.Windows.Ui;

// AI 润色 — 云端大模型设置页。1:1 还原 macOS CloudLLMTab(本地 llama 部分不实现)。
public sealed partial class SettingsForm
{
    // ---- macOS palette (exact) ----
    private static readonly Color CMarkGreenFg = Color.FromArgb(31, 207, 163), CMarkGreenBg = Color.FromArgb(15, 163, 128);
    private static readonly Color CMarkPurpleFg = Color.FromArgb(179, 168, 255), CMarkPurpleBg = Color.FromArgb(140, 122, 240);
    private static readonly Color CMarkBlueFg = Color.FromArgb(125, 161, 255), CMarkBlueBg = Color.FromArgb(59, 107, 255);
    private static readonly Color COk = Color.FromArgb(51, 212, 153), CErr = Color.FromArgb(245, 97, 122);
    private static readonly Color CWarn = Color.FromArgb(250, 189, 92), CLink = Color.FromArgb(158, 148, 255);
    private static Color CFieldBg => Theme.IsDark ? Theme.Hex("#16161C") : Theme.Hex("#F2F2F6");
    private static Color CInsetBg => Theme.IsDark ? Color.FromArgb(110, 0, 0, 0) : Color.FromArgb(14, 0, 0, 0);

    // transient tab state
    private bool _cloudShowKey;
    private bool _cloudRebuilding;   // true during RebuildCurrentTab → field Leave-commits are suppressed
    private (bool done, bool ok, int ping, string add, string msg) _cloudTest;
    private string? _cloudEditTpl;
    private string? _cloudEditProf;

    private List<CloudTemplate> _cloudTemplates = new();
    private List<CloudCustomProvider> _cloudCustoms = new();
    private List<CloudProfile> _cloudProfiles = new();

    private bool Zh => L10n.Resolved == Lang.Zh;

    // ===== entry =====
    private void BuildCloudLLM(Column col)
    {
        _cloudTemplates = CloudJson.Templates(S.CloudTemplatesJson);
        _cloudCustoms = CloudJson.CustomProviders(S.CloudCustomProvidersJson);
        _cloudProfiles = CloudJson.Profiles(S.CloudProfilesJson);
        CloudRequestLog.Shared.Enabled = S.CloudLogEnabled;

        CloudSection(col, Zh ? "云端大模型" : "Cloud LLM", CloudConfigCard());

        if (S.CloudEnabled)
        {
            CloudSection(col, Zh ? "最近请求 · 排查" : "Recent requests · debug", CloudLogCard());
            CloudSection(col, Zh ? "润色处理项 · 自动拼成 Prompt" : "Processing · builds the auto prompt", CloudModsCard());
            CloudSection(col, Zh ? "提示词模板" : "Prompt templates", CloudPromptCard());
        }
    }

    private void CloudCommit()
    {
        S.CloudTemplatesJson = CloudJson.Encode(_cloudTemplates);
        S.CloudCustomProvidersJson = CloudJson.Encode(_cloudCustoms);
        S.CloudProfilesJson = CloudJson.Encode(_cloudProfiles);
        _app.ApplyCloudSettings();
    }

    /// <summary>Section = a small muted label over a surface2 rounded card.</summary>
    private void CloudSection(Column col, string label, Control card)
    {
        col.AddRaw(new Label { Text = label, Font = Theme.Ui(9.5f), ForeColor = Theme.TextMuted, AutoSize = false,
            Height = 30, Padding = new Padding(2, 8, 0, 6), BackColor = Color.Transparent });
        col.AddRaw(card);
        col.Gap(14);
    }

    private LlmProvider CloudCurrentProvider()
    {
        if (!LlmProviders.IsBuiltin(S.CloudProvider))
        {
            var c = _cloudCustoms.FirstOrDefault(x => x.Id == S.CloudProvider);
            if (c is not null)
                return new LlmProvider { Key = c.Id, Label = c.Label, Mark = (c.Label.Length > 0 ? c.Label.Substring(0, 1).ToUpper() : "?"),
                    Cls = "custom", Desc = "自定义", BaseUrl = c.BaseURL, KeyHint = "API Key", ModelLabel = "模型 / 接入点 ID", DefaultModel = "" };
        }
        return LlmProviders.Find(S.CloudProvider);
    }

    private string CloudProviderLabel(string key)
    {
        if (LlmProviders.IsBuiltin(key)) return LlmProviders.LocalizedLabel(key, Zh);
        return _cloudCustoms.FirstOrDefault(c => c.Id == key)?.Label ?? (string.IsNullOrEmpty(key) ? "自定义" : key);
    }

    // ===== config card =====
    private Control CloudConfigCard()
    {
        var card = new RoundedPanel { Fill = Theme.Surface2, Border = Theme.Hairline, Radius = Theme.RadiusCard, BackColor = Theme.Surface };
        int W = _innerWidth, pad = 20, innerW = W - pad * 2;
        int y = 18;

        // header: title + 推荐 badge + toggle
        card.Controls.Add(new Label { Text = Zh ? "调用云端大模型" : "Use a cloud LLM", Font = Theme.Ui(13.5f, FontStyle.Bold),
            ForeColor = Theme.Text, AutoSize = false, Location = new Point(pad, y), Size = new Size(200, 24), BackColor = Color.Transparent });
        card.Controls.Add(CloudBadge(Zh ? "推荐" : "Recommended", CMarkPurpleFg, CMarkPurpleBg, pad + (Zh ? 132 : 150), y + 3));
        var enToggle = Toggle(S.CloudEnabled, on =>
        {
            S.CloudEnabled = on; _app.ApplyCloudSettings(); RebuildCurrentTab();
        });
        enToggle.Location = new Point(W - pad - enToggle.Width, y);
        card.Controls.Add(enToggle);
        y += 28;
        var desc = new Label { Text = Zh ? "润色质量更高、速度更快,需联网并消耗服务商额度。API Key 仅加密存储在本机,不会上传。"
                                         : "Higher quality + faster; needs the internet and uses your provider quota. The API key is encrypted on this machine only, never uploaded.",
            Font = Theme.Ui(9.5f), ForeColor = Theme.TextMuted, AutoSize = false, Location = new Point(pad, y),
            Size = new Size(innerW - 10, 36), BackColor = Color.Transparent };
        card.Controls.Add(desc);
        y += 40;

        if (S.CloudEnabled)
        {
            // profiles bar
            var pf = CloudProfilesBar(pad, y, innerW);
            card.Controls.Add(pf); y += pf.Height + 14;

            int half = (innerW - 16) / 2;
            // provider (opens picker)
            var prov = CloudCurrentProvider();
            y = CloudFieldLabel(card, Zh ? "服务商" : "Provider", pad, y);
            var provField = CloudInset(pad, y, half, 42);
            provField.Controls.Add(CloudMark(prov, 22, 11, 10));
            provField.Controls.Add(new Label { Text = CloudProviderLabel(S.CloudProvider), Font = Theme.Ui(10.5f), ForeColor = Theme.Text,
                AutoSize = false, Location = new Point(41, 0), Size = new Size(half - 41 - 24, 42), TextAlign = ContentAlignment.MiddleLeft, BackColor = Color.Transparent });
            provField.Controls.Add(new Label { Text = "▾", Font = Theme.Ui(9f), ForeColor = Theme.TextMuted, AutoSize = false,
                Location = new Point(half - 22, 0), Size = new Size(16, 42), TextAlign = ContentAlignment.MiddleCenter, BackColor = Color.Transparent });
            provField.Cursor = Cursors.Hand;
            CloudClickThrough(provField, () => OpenProviderPicker(provField));
            card.Controls.Add(provField);

            // model (text + preset dropdown)
            int mx = pad + half + 16;
            CloudFieldLabel(card, prov.ModelLabel, mx, y - 25);
            var modelField = CloudInset(mx, y, half, 42);
            var modelBox = new TextBox { Text = S.CloudModel, BorderStyle = BorderStyle.None, Font = Theme.Ui(10.5f), BackColor = CFieldBg,
                ForeColor = Theme.Text, Location = new Point(12, 12), Size = new Size(half - 12 - 28, 20) };
            modelBox.Leave += (_, _) => { if (_cloudRebuilding) return; S.CloudModel = modelBox.Text.Trim(); _cloudTest = default; _app.ApplyCloudSettings(); };
            modelField.Controls.Add(modelBox);
            if (prov.Models.Length > 0)
            {
                var mchev = new Label { Text = "▾", Font = Theme.Ui(9f), ForeColor = Theme.TextMuted, AutoSize = false,
                    Location = new Point(half - 24, 0), Size = new Size(18, 42), TextAlign = ContentAlignment.MiddleCenter, BackColor = Color.Transparent, Cursor = Cursors.Hand };
                mchev.Click += (_, _) => ShowModelMenu(prov, mchev, modelBox);
                modelField.Controls.Add(mchev);
            }
            card.Controls.Add(modelField);
            y += 42 + 12;

            // base url
            y = CloudFieldLabel(card, Zh ? "API 地址(Base URL)" : "API base URL", pad, y);
            var baseField = CloudInset(pad, y, innerW, 42);
            var baseBox = new TextBox { Text = S.CloudBaseURL, PlaceholderText = prov.BaseUrl, BorderStyle = BorderStyle.None, Font = Theme.Ui(10.5f), BackColor = CFieldBg,
                ForeColor = Theme.Text, Location = new Point(12, 12), Size = new Size(innerW - 24, 20) };
            baseBox.Leave += (_, _) => { if (_cloudRebuilding) return; S.CloudBaseURL = baseBox.Text.Trim(); _cloudTest = default; _app.ApplyCloudSettings(); };
            baseField.Controls.Add(baseBox); card.Controls.Add(baseField);
            y += 42 + 12;

            // api key + show/hide
            y = CloudFieldLabel(card, "API Key", pad, y);
            var keyField = CloudInset(pad, y, innerW, 42);
            var keyBox = new TextBox { Text = S.CloudApiKey, UseSystemPasswordChar = !_cloudShowKey, BorderStyle = BorderStyle.None,
                Font = Theme.Mono(10f), BackColor = CFieldBg, ForeColor = Theme.Text, Location = new Point(12, 12), Size = new Size(innerW - 12 - 66, 20) };
            keyBox.Leave += (_, _) => { if (_cloudRebuilding) return; S.CloudApiKey = keyBox.Text; _cloudTest = default; _app.ApplyCloudSettings(); };
            keyField.Controls.Add(keyBox);
            var showBtn = new Label { Text = _cloudShowKey ? (Zh ? "隐藏" : "Hide") : (Zh ? "显示" : "Show"), Font = Theme.Ui(9f),
                ForeColor = Theme.TextMuted, AutoSize = false, Location = new Point(innerW - 58, 9), Size = new Size(48, 24),
                TextAlign = ContentAlignment.MiddleCenter, BackColor = CInsetBg, Cursor = Cursors.Hand };
            showBtn.Click += (_, _) => { S.CloudApiKey = keyBox.Text; _cloudShowKey = !_cloudShowKey; RebuildCurrentTab(); };
            keyField.Controls.Add(showBtn); card.Controls.Add(keyField);
            y += 42 + 12;

            // temperature + max tokens
            CloudFieldLabel(card, Zh ? "Temperature(0~1,润色建议 0.3)" : "Temperature (0–1)", pad, y, half);
            CloudFieldLabel(card, Zh ? "Max Tokens(最大输出长度)" : "Max tokens", mx, y, half);
            y += 25;
            var tempField = CloudInset(pad, y, half, 42);
            var tempBox = new TextBox { Text = S.CloudTemperature.ToString("0.##"), BorderStyle = BorderStyle.None, Font = Theme.Ui(10.5f),
                BackColor = CFieldBg, ForeColor = Theme.Text, Location = new Point(12, 12), Size = new Size(half - 24, 20) };
            tempBox.Leave += (_, _) => { if (_cloudRebuilding) return; if (double.TryParse(tempBox.Text, out var t)) { S.CloudTemperature = Math.Min(2, Math.Max(0, t)); _app.ApplyCloudSettings(); } };
            tempField.Controls.Add(tempBox); card.Controls.Add(tempField);
            var maxField = CloudInset(mx, y, half, 42);
            var maxBox = new TextBox { Text = S.CloudMaxTokens.ToString(), BorderStyle = BorderStyle.None, Font = Theme.Ui(10.5f),
                BackColor = CFieldBg, ForeColor = Theme.Text, Location = new Point(12, 12), Size = new Size(half - 24, 20) };
            maxBox.Leave += (_, _) => { if (_cloudRebuilding) return; if (int.TryParse(maxBox.Text, out var n)) { S.CloudMaxTokens = Math.Max(1, n); _app.ApplyCloudSettings(); } };
            maxField.Controls.Add(maxBox); card.Controls.Add(maxField);
            y += 42 + 18;

            // test connection
            var testBtn = new VibeButton { Text = Zh ? "测试连接与延迟" : "Test connection", Style = VibeButton.Kind.Ghost, Size = new Size(Zh ? 140 : 150, 40), Location = new Point(pad, y) };
            var testStatus = new Label { Font = Theme.Ui(9.5f), ForeColor = Theme.TextMuted, AutoSize = false,
                Location = new Point(pad + testBtn.Width + 14, y), Size = new Size(innerW - testBtn.Width - 14, 40), TextAlign = ContentAlignment.MiddleLeft, BackColor = Color.Transparent };
            if (_cloudTest.done)
                testStatus.Text = _cloudTest.ok ? (Zh ? $"● 连接正常 · 单次往返 {_cloudTest.ping}ms · 整段润色约 {_cloudTest.add}" : $"● OK · {_cloudTest.ping}ms RTT · refine ≈ {_cloudTest.add}")
                                                : (Zh ? $"● 测试失败 · {_cloudTest.msg}" : $"● Failed · {_cloudTest.msg}");
            else testStatus.Text = Zh ? "会发送一次极短请求,测量真实往返延迟。" : "Sends one tiny request to measure real round-trip latency.";
            testStatus.ForeColor = _cloudTest.done ? (_cloudTest.ok ? COk : CErr) : Theme.TextMuted;
            testBtn.Click += async (_, _) =>
            {
                S.CloudApiKey = keyBox.Text; S.CloudBaseURL = baseBox.Text.Trim(); S.CloudModel = modelBox.Text.Trim(); _app.ApplyCloudSettings();
                testBtn.Enabled = false; testStatus.ForeColor = Theme.TextMuted; testStatus.Text = Zh ? "测试中…" : "Testing…";
                var r = await CloudRefiner.TestConnectionAsync(S.CloudBaseURL, S.CloudModel, S.CloudApiKey);
                _cloudTest = (true, r.ok, r.ping, r.add, r.msg);
                testBtn.Enabled = true;
                testStatus.ForeColor = r.ok ? COk : CErr;
                testStatus.Text = r.ok ? (Zh ? $"● 连接正常 · 单次往返 {r.ping}ms · 整段润色约 {r.add}" : $"● OK · {r.ping}ms RTT · refine ≈ {r.add}")
                                       : (Zh ? $"● 测试失败 · {r.msg}" : $"● Failed · {r.msg}");
            };
            card.Controls.Add(testBtn); card.Controls.Add(testStatus);
            y += 40 + 13;

            // price
            card.Controls.Add(new Label { Text = "💳 " + prov.Price, Font = Theme.Ui(9.5f), ForeColor = Theme.TextMuted, AutoSize = false,
                Location = new Point(pad, y), Size = new Size(innerW, 20), BackColor = Color.Transparent });
            y += 22;
        }

        card.Width = W; card.Height = y + 18;
        return card;
    }

    // ===== mods card =====
    private Control CloudModsCard()
    {
        var card = new RoundedPanel { Fill = Theme.Surface2, Border = Theme.Hairline, Radius = Theme.RadiusCard, BackColor = Theme.Surface, Width = _innerWidth };
        (string t, string h, Func<bool> get, Action<bool> set)[] rows =
        {
            (Zh ? "数字规整" : "Numbers → digits", Zh ? "把口语数字转成阿拉伯:一百二十三 → 123、三点半 → 3:30、百分之二十 → 20%。成语、计数词不动。" : "Spoken numerals → digits.", () => S.CloudNumbers, v => S.CloudNumbers = v),
            (Zh ? "去口水词" : "Remove fillers", Zh ? "去掉「嗯 / 呃 / 唉」和口吃重复(那个那个 → 那个)。叠词(看看 / 想想)保留。" : "Strip 嗯/呃/唉 and stutters.", () => S.CloudFillers, v => S.CloudFillers = v),
            (Zh ? "改口纠正" : "Keep restatement", Zh ? "说话中途自我更正时,只保留最终说法,删掉被改掉的前半句。" : "On self-correction, keep only the final wording.", () => S.CloudRestate, v => S.CloudRestate = v),
            (Zh ? "热词修正" : "Apply hotwords", Zh ? "参照「词典」里的专有名词与术语,修正同音 / 近音误写。词条在「词典」页维护。" : "Fix homophones using the 词典 hotword list.", () => S.CloudHotwords, v => S.CloudHotwords = v),
        };
        int y = 0;
        foreach (var (t, h, get, set) in rows)
        {
            var r = Row(t, h, Toggle(get(), v => { set(v); _app.ApplyCloudSettings(); }));
            r.Location = new Point(0, y); r.Width = _innerWidth; card.Controls.Add(r); y += r.Height;
        }
        card.Height = y;
        return card;
    }

    // ===== request log card =====
    private Control CloudLogCard()
    {
        var card = new RoundedPanel { Fill = Theme.Surface2, Border = Theme.Hairline, Radius = Theme.RadiusCard, BackColor = Theme.Surface, Width = _innerWidth };
        int W = _innerWidth, pad = 18, innerW = W - pad * 2, y = 16;
        card.Controls.Add(new Label { Text = Zh ? "记录每次云端调用,便于排查 / 提 issue · 最近 20 条" : "Logs each cloud call for debugging · last 20",
            Font = Theme.Ui(9.5f), ForeColor = Theme.TextMuted, AutoSize = false, Location = new Point(pad, y + 4), Size = new Size(innerW - 230, 32), BackColor = Color.Transparent });
        // 记录 toggle + 清空
        var logTog = Toggle(S.CloudLogEnabled, v => { S.CloudLogEnabled = v; _app.ApplyCloudSettings(); RebuildCurrentTab(); });
        logTog.Location = new Point(W - pad - logTog.Width, y + 4); card.Controls.Add(logTog);
        card.Controls.Add(new Label { Text = Zh ? "记录" : "Log", Font = Theme.Ui(9.5f), ForeColor = Theme.TextMuted, AutoSize = false,
            Location = new Point(W - pad - logTog.Width - 44, y + 4), Size = new Size(40, 24), TextAlign = ContentAlignment.MiddleRight, BackColor = Color.Transparent });
        if (S.CloudLogEnabled)
        {
            var clear = new Label { Text = Zh ? "清空" : "Clear", Font = Theme.Ui(9f), ForeColor = Theme.TextMuted, AutoSize = false,
                Location = new Point(W - pad - logTog.Width - 100, y + 4), Size = new Size(48, 24), TextAlign = ContentAlignment.MiddleRight, BackColor = Color.Transparent, Cursor = Cursors.Hand };
            clear.Click += (_, _) => { CloudRequestLog.Shared.Clear(); RebuildCurrentTab(); };
            card.Controls.Add(clear);
        }
        y += 40;

        var entries = CloudRequestLog.Shared.Snapshot().Take(8).ToList();
        if (!S.CloudLogEnabled)
        {
            card.Controls.Add(new Label { Text = Zh ? "「记录请求」已关闭。打开后保存最近 20 条(输入→输出 + 提示词),用于排查或一键提 issue。" : "Logging is off.",
                Font = Theme.Ui(9f), ForeColor = Theme.TextMuted, AutoSize = false, Location = new Point(pad, y), Size = new Size(innerW, 32), BackColor = Color.Transparent });
            y += 34;
        }
        else if (entries.Count == 0)
        {
            card.Controls.Add(new Label { Text = Zh ? "还没有记录。说一段话(≥6 字),这里会列出每次云端请求:从「原始 ASR」改成「结果」、耗时与成功 / 超时 / 失败。" : "No requests yet — dictate (≥6 chars) and they'll appear here.",
                Font = Theme.Ui(9f), ForeColor = Theme.TextMuted, AutoSize = false, Location = new Point(pad, y), Size = new Size(innerW, 36), BackColor = Color.Transparent });
            y += 38;
        }
        else
        {
            foreach (var e in entries)
            {
                var dot = new Panel { Size = new Size(8, 8), Location = new Point(pad, y + 5), BackColor = Color.Transparent };
                var col = CloudLogColor(e.Status);
                dot.Paint += (s, ev) => { ev.Graphics.SmoothingMode = SmoothingMode.AntiAlias; using var b = new SolidBrush(col); ev.Graphics.FillEllipse(b, 0, 0, 7, 7); };
                card.Controls.Add(dot);
                card.Controls.Add(new Label { Text = $"{e.At:HH:mm:ss}  {CloudProviderLabel(e.Provider)} · {e.Model}", Font = Theme.Ui(9f), ForeColor = Theme.Text,
                    AutoSize = false, Location = new Point(pad + 16, y), Size = new Size(innerW - 200, 18), BackColor = Color.Transparent });
                card.Controls.Add(new Label { Text = $"{e.Ms}ms  {CloudLogText(e.Status)}", Font = Theme.Mono(8.5f), ForeColor = col,
                    AutoSize = false, Location = new Point(W - pad - 150, y), Size = new Size(150, 18), TextAlign = ContentAlignment.MiddleRight, BackColor = Color.Transparent });
                y += 19;
                string change = e.Status != "ok" ? $"「{Clip(e.Input, 40)}」 · {CloudLogText(e.Status)}:{Clip(e.Output, 60)}"
                              : e.Input.Trim() == e.Output.Trim() ? $"「{Clip(e.Input, 60)}」 · {(Zh ? "无修改" : "no change")}"
                              : (Zh ? $"从「{Clip(e.Input, 36)}」改成「{Clip(e.Output, 36)}」" : $"{Clip(e.Input, 36)} → {Clip(e.Output, 36)}");
                card.Controls.Add(new Label { Text = change, Font = Theme.Ui(8.5f), ForeColor = Theme.TextMuted, AutoSize = false,
                    Location = new Point(pad + 16, y), Size = new Size(innerW - 16, 16), BackColor = Color.Transparent });
                y += 22;
                var sep = new Panel { Location = new Point(pad, y), Size = new Size(innerW, 1), BackColor = Theme.Hairline };
                card.Controls.Add(sep); y += 9;
            }
        }
        card.Height = y + 6;
        return card;
    }

    // ===== prompt template studio =====
    private Control CloudPromptCard()
    {
        var card = new RoundedPanel { Fill = Theme.Surface2, Border = Theme.Hairline, Radius = Theme.RadiusCard, BackColor = Theme.Surface, Width = _innerWidth };
        int W = _innerWidth, pad = 20, innerW = W - pad * 2, y = 16;

        // template chips
        int cx = pad;
        cx = AddTemplateChip(card, "⚡ " + (Zh ? "自动" : "Auto"), S.CloudActiveTemplate == "auto", cx, y, () => { S.CloudActiveTemplate = "auto"; _app.ApplyCloudSettings(); RebuildCurrentTab(); }, null);
        foreach (var t in _cloudTemplates)
        {
            var tid = t.Id;
            cx = AddTemplateChip(card, t.Name, S.CloudActiveTemplate == tid, cx, y,
                () => { S.CloudActiveTemplate = tid; _app.ApplyCloudSettings(); RebuildCurrentTab(); },
                () => { _cloudTemplates.RemoveAll(x => x.Id == tid); if (S.CloudActiveTemplate == tid) S.CloudActiveTemplate = "auto"; CloudCommit(); RebuildCurrentTab(); });
            if (cx > innerW - 120) { cx = pad; y += 40; }
        }
        var addTpl = new VibeButton { Text = Zh ? "＋ 新建模板" : "＋ New", Style = VibeButton.Kind.Ghost, Size = new Size(96, 34), Location = new Point(cx, y) };
        addTpl.Click += (_, _) =>
        {
            int n = _cloudTemplates.Count + 1; var id = $"t{n}-{_cloudTemplates.Count}";
            _cloudTemplates.Add(new CloudTemplate { Id = id, Name = (Zh ? "模板" : "Tpl") + n, Content = CloudCurrentPrompt() });
            S.CloudActiveTemplate = id; CloudCommit(); RebuildCurrentTab();
        };
        card.Controls.Add(addTpl);
        y += 34 + 12;

        // placeholder toolbar
        card.Controls.Add(new Label { Text = Zh ? "插入占位符" : "Insert token", Font = Theme.Ui(9f), ForeColor = Theme.TextMuted, AutoSize = false,
            Location = new Point(pad, y + 4), Size = new Size(72, 22), BackColor = Color.Transparent });
        int tx = pad + 76;
        TextBox? editorRef = null;
        foreach (var (token, _) in CloudSeeds.Tokens)
        {
            var chip = new Label { Text = token, Font = Theme.Mono(8.5f), ForeColor = CLink, AutoSize = false, Location = new Point(tx, y),
                Size = new Size(TextRenderer.MeasureText(token, Theme.Mono(8.5f)).Width + 16, 22), TextAlign = ContentAlignment.MiddleCenter,
                BackColor = Color.FromArgb(30, CMarkPurpleBg.R, CMarkPurpleBg.G, CMarkPurpleBg.B), Cursor = Cursors.Hand };
            var tok = token;
            chip.Click += (_, _) => { if (editorRef is not null) { int p = editorRef.SelectionStart; editorRef.Text = editorRef.Text.Insert(p, tok); editorRef.SelectionStart = p + tok.Length; editorRef.Focus(); } };
            card.Controls.Add(chip);
            tx += chip.Width + 8;
        }
        y += 30;

        // editor
        var editorHost = CloudInset(pad, y, innerW, 168);
        var editor = new TextBox { Multiline = true, ScrollBars = ScrollBars.Vertical, BorderStyle = BorderStyle.None, Font = Theme.Mono(9.5f),
            BackColor = CFieldBg, ForeColor = Theme.Text, Location = new Point(8, 8), Size = new Size(innerW - 16, 152), Text = CloudCurrentPrompt() };
        editor.Leave += (_, _) =>
        {
            var v = editor.Text;
            if (S.CloudActiveTemplate == "auto") S.CloudAutoOverride = v;
            else { var t = _cloudTemplates.FirstOrDefault(x => x.Id == S.CloudActiveTemplate); if (t is not null) t.Content = v; }
            CloudCommit();
        };
        editorRef = editor;
        editorHost.Controls.Add(editor); card.Controls.Add(editorHost);
        y += 168 + 10;

        card.Controls.Add(new Label { Text = Zh ? "「自动」由上方开关实时拼成;改后可恢复自动。模板可增删、点选即套用。占位符调用时自动替换(热词取自「词典」)。" : "“Auto” is built from the toggles above. Templates: click to apply. Tokens are filled at call time.",
            Font = Theme.Ui(8.5f), ForeColor = Theme.TextMuted, AutoSize = false, Location = new Point(pad, y), Size = new Size(innerW, 32), BackColor = Color.Transparent });
        y += 34;

        card.Height = y;
        return card;
    }

    private string CloudCurrentPrompt()
    {
        if (S.CloudActiveTemplate == "auto")
            return string.IsNullOrEmpty(S.CloudAutoOverride) ? CloudPrompt.BuildAuto(S.CloudNumbers, S.CloudFillers, S.CloudRestate, S.CloudHotwords) : S.CloudAutoOverride;
        return _cloudTemplates.FirstOrDefault(t => t.Id == S.CloudActiveTemplate)?.Content ?? "";
    }

    // ===== profiles bar =====
    private Control CloudProfilesBar(int x, int y, int w)
    {
        var host = new Panel { Location = new Point(x, y), Size = new Size(w, 64), BackColor = Color.Transparent };
        host.Controls.Add(new Label { Text = Zh ? "我的配置 · 保存当前设置,一键切换(点选套用)" : "My profiles · save + one-tap switch",
            Font = Theme.Ui(9f), ForeColor = Theme.TextMuted, AutoSize = false, Location = new Point(0, 0), Size = new Size(w, 18), BackColor = Color.Transparent });
        int cx = 0, cy = 26;
        foreach (var p in _cloudProfiles)
        {
            var chip = new Label { Text = $"{p.Name} · {CloudProviderLabel(p.Provider)}   ✕", Font = Theme.Ui(9.5f), ForeColor = Theme.Text,
                AutoSize = false, Size = new Size(TextRenderer.MeasureText($"{p.Name} · {CloudProviderLabel(p.Provider)}   ✕", Theme.Ui(9.5f)).Width + 20, 32),
                Location = new Point(cx, cy), TextAlign = ContentAlignment.MiddleCenter, BackColor = CInsetBg, Cursor = Cursors.Hand };
            var pid = p.Id;
            chip.MouseClick += (_, me) =>
            {
                if (me.X > chip.Width - 24) { _cloudProfiles.RemoveAll(z => z.Id == pid); CloudCommit(); RebuildCurrentTab(); }
                else { var prof = _cloudProfiles.FirstOrDefault(z => z.Id == pid); if (prof is not null) CloudLoadProfile(prof); }
            };
            host.Controls.Add(chip); cx += chip.Width + 8;
        }
        var save = new Label { Text = Zh ? "＋ 保存当前为配置" : "＋ Save current", Font = Theme.Ui(9.5f), ForeColor = CLink, AutoSize = false,
            Size = new Size(Zh ? 152 : 130, 32), Location = new Point(cx, cy), TextAlign = ContentAlignment.MiddleCenter, BackColor = Color.Transparent, Cursor = Cursors.Hand };
        save.Click += (_, _) =>
        {
            int n = _cloudProfiles.Count + 1; var id = $"prof{n}";
            while (_cloudProfiles.Any(z => z.Id == id)) { n++; id = $"prof{n}"; }
            var prof = new CloudProfile { Id = id, Name = (Zh ? "配置" : "Profile") + n, Provider = S.CloudProvider, BaseURL = S.CloudBaseURL,
                Model = S.CloudModel, Temperature = S.CloudTemperature, MaxTokens = S.CloudMaxTokens, Numbers = S.CloudNumbers,
                Fillers = S.CloudFillers, Restate = S.CloudRestate, Hotwords = S.CloudHotwords, ActiveTemplate = S.CloudActiveTemplate, AutoOverride = S.CloudAutoOverride };
            SecretStore.Set("cloud_profile_" + id, S.CloudApiKey);
            _cloudProfiles.Add(prof); CloudCommit(); RebuildCurrentTab();
        };
        host.Controls.Add(save);
        return host;
    }

    private void CloudLoadProfile(CloudProfile p)
    {
        S.CloudProvider = p.Provider; S.CloudBaseURL = p.BaseURL; S.CloudModel = p.Model;
        S.CloudTemperature = p.Temperature; S.CloudMaxTokens = p.MaxTokens;
        S.CloudNumbers = p.Numbers; S.CloudFillers = p.Fillers; S.CloudRestate = p.Restate; S.CloudHotwords = p.Hotwords;
        S.CloudActiveTemplate = p.ActiveTemplate; S.CloudAutoOverride = p.AutoOverride;
        var k = SecretStore.Get("cloud_profile_" + p.Id); if (!string.IsNullOrEmpty(k)) S.CloudApiKey = k;
        _cloudTest = default; CloudCommit(); RebuildCurrentTab();
    }

    // ===== small helpers =====
    private static string Clip(string s, int n) { s = (s ?? "").Replace("\n", " ").Trim(); return s.Length > n ? s.Substring(0, n) + "…" : s; }
    private static Color CloudLogColor(string s) => s == "ok" ? COk : (s is "timeout" or "skipped" ? CWarn : CErr);
    private string CloudLogText(string s) => s switch { "ok" => Zh ? "成功" : "ok", "timeout" => Zh ? "超时" : "timeout", "skipped" => Zh ? "超 token" : "skipped", _ => Zh ? "失败" : "error" };

    private int CloudFieldLabel(Control parent, string text, int x, int y, int w = 360)
    {
        parent.Controls.Add(new Label { Text = text, Font = Theme.Ui(9f, FontStyle.Bold), ForeColor = Theme.TextMuted, AutoSize = false,
            Location = new Point(x, y), Size = new Size(w, 18), BackColor = Color.Transparent });
        return y + 25;
    }

    private RoundedPanel CloudInset(int x, int y, int w, int h)
        => new() { Fill = CFieldBg, Border = Theme.Hairline, Radius = 10, Location = new Point(x, y), Size = new Size(w, h), BackColor = Theme.Surface2 };

    private Label CloudBadge(string text, Color fg, Color bg, int x, int y)
        => new() { Text = text, Font = Theme.Ui(8.5f, FontStyle.Bold), ForeColor = fg, AutoSize = false,
            Size = new Size(TextRenderer.MeasureText(text, Theme.Ui(8.5f, FontStyle.Bold)).Width + 16, 18), Location = new Point(x, y),
            TextAlign = ContentAlignment.MiddleCenter, BackColor = Color.FromArgb(41, bg.R, bg.G, bg.B) };

    private Control CloudMark(LlmProvider p, int size, int mx, int my)
    {
        var (fg, bg) = p.Cls == "oa" ? (CMarkGreenFg, CMarkGreenBg) : p.Cls == "custom" ? (CMarkPurpleFg, CMarkPurpleBg) : (CMarkBlueFg, CMarkBlueBg);
        var pnl = new Panel { Size = new Size(size, size), Location = new Point(mx, my), BackColor = Color.Transparent };
        pnl.Paint += (s, e) =>
        {
            var g = e.Graphics; g.SmoothingMode = SmoothingMode.AntiAlias;
            using var path = Theme.RoundedRect(new RectangleF(0, 0, size, size), 6);
            using var b = new SolidBrush(Color.FromArgb(33, bg.R, bg.G, bg.B));
            g.FillPath(b, path);
            TextRenderer.DrawText(g, p.Mark, Theme.Ui(8.5f, FontStyle.Bold), new Rectangle(0, 0, size, size), fg,
                TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.NoPadding);
        };
        return pnl;
    }

    private static void CloudClickThrough(Control host, Action onClick)
    {
        host.Click += (_, _) => onClick();
        foreach (Control c in host.Controls) { c.Click += (_, _) => onClick(); if (c is Label) c.Cursor = Cursors.Hand; }
    }

    private int _addTplX;
    private int AddTemplateChip(Control card, string name, bool active, int x, int y, Action onClick, Action? onDelete)
    {
        int wText = TextRenderer.MeasureText(name, Theme.Ui(9.5f)).Width;
        int w = wText + (onDelete != null ? 34 : 24);
        var chip = new Label { Text = name + (onDelete != null ? "   ✕" : ""), Font = Theme.Ui(9.5f, active ? FontStyle.Bold : FontStyle.Regular),
            ForeColor = active ? Color.White : Theme.Text, AutoSize = false, Size = new Size(w, 34), Location = new Point(x, y),
            TextAlign = ContentAlignment.MiddleCenter, Cursor = Cursors.Hand,
            BackColor = active ? Color.FromArgb(72, CMarkPurpleBg.R, CMarkPurpleBg.G, CMarkPurpleBg.B) : CInsetBg };
        chip.MouseClick += (_, me) =>
        {
            if (onDelete != null && me.X > chip.Width - 22) onDelete();
            else onClick();
        };
        card.Controls.Add(chip);
        return x + w + 8;
    }

    private void ShowModelMenu(LlmProvider p, Control anchor, TextBox modelBox)
    {
        var menu = new ContextMenuStrip { Font = Theme.Ui(9.5f) };
        foreach (var m in p.Models)
        {
            var item = new ToolStripMenuItem(string.IsNullOrEmpty(m.Note) ? m.Label : $"{m.Label}   ({m.Note})");
            var id = m.Id;
            item.Click += (_, _) => { modelBox.Text = id; S.CloudModel = id; _app.ApplyCloudSettings(); };
            menu.Items.Add(item);
        }
        menu.Show(anchor, new Point(0, anchor.Height));
    }

    private void OpenProviderPicker(Control anchor)
    {
        var pop = new CloudProviderPopup(this, _cloudCustoms, S.CloudProvider);
        pop.OnPick = key =>
        {
            S.CloudProvider = key;
            if (LlmProviders.IsBuiltin(key)) { var pr = LlmProviders.Find(key); S.CloudBaseURL = pr.BaseUrl; S.CloudModel = string.IsNullOrEmpty(pr.DefaultModel) ? (pr.Models.FirstOrDefault()?.Id ?? "") : pr.DefaultModel; }
            else { var c = _cloudCustoms.FirstOrDefault(z => z.Id == key); if (c is not null) S.CloudBaseURL = c.BaseURL; }
            _cloudTest = default; CloudCommit(); RebuildCurrentTab();
        };
        pop.OnCustomsChanged = list => { _cloudCustoms = list; CloudCommit(); };
        var sp = anchor.PointToScreen(new Point(0, anchor.Height + 4));
        pop.Show(sp);
    }
}

/// <summary>Provider picker popup: 23 built-ins (with colored marks) + custom providers (add / delete).</summary>
internal sealed class CloudProviderPopup : Form
{
    public Action<string>? OnPick;
    public Action<List<CloudCustomProvider>>? OnCustomsChanged;
    private readonly List<CloudCustomProvider> _customs;
    private readonly string _current;

    public CloudProviderPopup(IWin32Window owner, List<CloudCustomProvider> customs, string current)
    {
        _customs = customs.Select(c => new CloudCustomProvider { Id = c.Id, Label = c.Label, BaseURL = c.BaseURL }).ToList();
        _current = current;
        FormBorderStyle = FormBorderStyle.None; StartPosition = FormStartPosition.Manual; ShowInTaskbar = false;
        BackColor = Theme.Surface2; Width = 340;
        Deactivate += (_, _) => Close();
        Build();
    }

    public void Show(Point screenPt) { Location = screenPt; Show(); BringToFront(); }

    private void Build()
    {
        Controls.Clear();
        int y = 10, w = Width;
        bool zh = L10n.Resolved == Lang.Zh;
        Controls.Add(new Label { Text = zh ? "选择服务商" : "Choose provider", Font = Theme.Ui(9f), ForeColor = Theme.TextMuted, AutoSize = false,
            Location = new Point(12, y), Size = new Size(w - 24, 18), BackColor = Color.Transparent });
        y += 24;
        foreach (var p in LlmProviders.All)
            y = Row(p.Key, p.Mark, LlmProviders.LocalizedLabel(p.Key, zh), p.Cls, false, y);
        if (_customs.Count > 0)
        {
            Controls.Add(new Panel { Location = new Point(12, y + 2), Size = new Size(w - 24, 1), BackColor = Theme.Hairline }); y += 8;
            foreach (var c in _customs)
                y = Row(c.Id, c.Label.Length > 0 ? c.Label.Substring(0, 1).ToUpper() : "?", c.Label, "custom", true, y);
        }
        Controls.Add(new Panel { Location = new Point(12, y + 2), Size = new Size(w - 24, 1), BackColor = Theme.Hairline }); y += 8;
        var add = new Label { Text = "＋ 新增服务商", Font = Theme.Ui(10f), ForeColor = Color.FromArgb(158, 148, 255), AutoSize = false,
            Location = new Point(12, y), Size = new Size(w - 24, 34), TextAlign = ContentAlignment.MiddleLeft, Padding = new Padding(8, 0, 0, 0), BackColor = Color.Transparent, Cursor = Cursors.Hand };
        add.Click += (_, _) => AddCustom();
        Controls.Add(add); y += 40;
        Height = y;
    }

    private int Row(string id, string mark, string label, string cls, bool custom, int y)
    {
        int w = Width;
        bool sel = id == _current;
        var row = new Panel { Location = new Point(8, y), Size = new Size(w - 16, 34), BackColor = sel ? Color.FromArgb(13, 255, 255, 255) : Color.Transparent, Cursor = Cursors.Hand };
        var markPnl = new Label { Text = mark, Font = Theme.Ui(8.5f, FontStyle.Bold), ForeColor = Theme.Text, AutoSize = false,
            Location = new Point(6, 7), Size = new Size(20, 20), TextAlign = ContentAlignment.MiddleCenter, BackColor = Color.FromArgb(16, 255, 255, 255) };
        row.Controls.Add(markPnl);
        row.Controls.Add(new Label { Text = label, Font = Theme.Ui(10f), ForeColor = Theme.Text, AutoSize = false,
            Location = new Point(34, 0), Size = new Size(w - 16 - 34 - (custom ? 60 : 24), 34), TextAlign = ContentAlignment.MiddleLeft, BackColor = Color.Transparent });
        if (sel) row.Controls.Add(new Label { Text = "✓", Font = Theme.Ui(10f, FontStyle.Bold), ForeColor = Color.FromArgb(158, 148, 255), AutoSize = false,
            Location = new Point(w - 16 - 24, 0), Size = new Size(20, 34), TextAlign = ContentAlignment.MiddleCenter, BackColor = Color.Transparent });
        void pick() { OnPick?.Invoke(id); Close(); }
        row.Click += (_, _) => pick(); markPnl.Click += (_, _) => pick();
        foreach (Control c in row.Controls) if (c.Text == label) c.Click += (_, _) => pick();
        if (custom)
        {
            var del = new Label { Text = "🗑", Font = Theme.Ui(9f), ForeColor = Color.FromArgb(245, 97, 122), AutoSize = false,
                Location = new Point(w - 16 - 26, 0), Size = new Size(22, 34), TextAlign = ContentAlignment.MiddleCenter, BackColor = Color.Transparent, Cursor = Cursors.Hand };
            del.Click += (_, _) => { _customs.RemoveAll(z => z.Id == id); OnCustomsChanged?.Invoke(_customs); Build(); };
            row.Controls.Add(del);
        }
        Controls.Add(row);
        return y + 36;
    }

    private void AddCustom()
    {
        int n = _customs.Count + 1; var id = $"cust{n}";
        while (_customs.Any(z => z.Id == id) || LlmProviders.IsBuiltin(id)) { n++; id = $"cust{n}"; }
        // simple inline prompt via two input dialogs
        var label = Prompt("新增服务商", "名称(如 DeepSeek / 本地 Ollama):");
        if (string.IsNullOrWhiteSpace(label)) return;
        var url = Prompt("新增服务商", "API 地址(Base URL,兼容 OpenAI /chat/completions):", "https://");
        if (string.IsNullOrWhiteSpace(url)) return;
        _customs.Add(new CloudCustomProvider { Id = id, Label = label.Trim(), BaseURL = url.Trim() });
        OnCustomsChanged?.Invoke(_customs);
        OnPick?.Invoke(id); Close();
    }

    private static string? Prompt(string title, string text, string initial = "")
    {
        using var f = new Form { Text = title, FormBorderStyle = FormBorderStyle.FixedDialog, StartPosition = FormStartPosition.CenterParent,
            Width = 420, Height = 150, MaximizeBox = false, MinimizeBox = false, BackColor = Theme.Surface };
        var lbl = new Label { Text = text, ForeColor = Theme.Text, AutoSize = false, Location = new Point(14, 12), Size = new Size(390, 36), Font = Theme.Ui(9.5f) };
        var box = new TextBox { Text = initial, Location = new Point(14, 52), Width = 390, Font = Theme.Ui(10f) };
        var ok = new VibeButton { Text = "保存", Style = VibeButton.Kind.Solid, Size = new Size(80, 30), Location = new Point(324, 86) };
        ok.Click += (_, _) => { f.DialogResult = DialogResult.OK; f.Close(); };
        f.Controls.Add(lbl); f.Controls.Add(box); f.Controls.Add(ok); f.AcceptButton = null;
        box.KeyDown += (_, e) => { if (e.KeyCode == Keys.Enter) { f.DialogResult = DialogResult.OK; f.Close(); } };
        return f.ShowDialog() == DialogResult.OK ? box.Text : null;
    }
}
