using System;
using System.Drawing;
using System.Windows.Forms;

namespace VibeXASR.Windows.Ui;

/// <summary>
/// First-run onboarding wizard — Windows-specific (intentionally NOT a port of the macOS
/// Accessibility/Input-Monitoring flow; on Windows a normal app gets global hotkey + SendInput
/// for free). It solves the two Windows confusions:
///   1. "Where did it go?" — there is no main window; the app lives in the BOTTOM-RIGHT system
///      tray (and Windows hides tray icons under the ⌃ overflow by default).
///   2. "Why isn't it working yet?" — the local model load is slower than macOS, so step 3 shows
///      a LIVE engine-preparing status so the user waits instead of assuming it's broken.
/// Shown immediately on first launch (does NOT wait for the engine). Dismiss sets
/// <see cref="Storage.Settings.Welcomed"/>; re-runnable from the tray menu.
/// </summary>
public sealed class OnboardingForm : Form
{
    private readonly IAppController _app;
    private readonly bool _zh;
    private readonly string _keyName;
    private int _step;
    private const int StepCount = 3;

    private readonly VibeButton _next, _back, _skip;
    private readonly VibeToggle _launch;
    private readonly Label _launchLabel;
    private readonly System.Windows.Forms.Timer _poll = new() { Interval = 400 };

    public OnboardingForm(IAppController app)
    {
        _app = app;
        _zh = L10n.Resolved is Lang.Zh or Lang.Hant;
        _keyName = VkNames.Name(app.Settings.HotkeyVk);

        FormBorderStyle = FormBorderStyle.None;
        StartPosition = FormStartPosition.CenterScreen;
        ShowInTaskbar = true;
        TopMost = true;                 // float above the active app (we can't steal focus)
        DoubleBuffered = true;
        BackColor = Theme.Surface;
        ClientSize = new Size(484, 452);
        Icon = Branding.AppIcon;
        Text = "Vibe XASR";

        _back = new VibeButton { Text = _zh ? "上一步" : "Back", Style = VibeButton.Kind.Ghost, Size = new Size(92, 38) };
        _next = new VibeButton { Text = "", Style = VibeButton.Kind.Solid, Size = new Size(150, 40) };
        _skip = new VibeButton { Text = "✕", Style = VibeButton.Kind.Ghost, Size = new Size(30, 28) };
        _back.Click += (_, _) => { if (_step > 0) { _step--; Sync(); } };
        _next.Click += (_, _) => { if (_step < StepCount - 1) { _step++; Sync(); } else Dismiss(); };
        _skip.Click += (_, _) => Dismiss();

        _launch = new VibeToggle { Checked = app.Settings.LaunchAtLogin };
        _launch.CheckedChanged += (_, _) => _app.SetLaunchAtLogin(_launch.Checked);
        _launchLabel = new Label
        {
            Text = _zh ? "开机自启动" : "Launch at login", Font = Theme.Ui(11f), ForeColor = Theme.Text,
            AutoSize = true, BackColor = Color.Transparent,
        };

        Controls.AddRange(new Control[] { _back, _next, _skip, _launch, _launchLabel });
        // While on the "ready" step, poll engine readiness so the status flips live to "ready".
        _poll.Tick += (_, _) => { if (_step == StepCount - 1) { UpdateNextLabel(); Invalidate(); } };
        _poll.Start();
        Sync();
    }

    private void Sync()
    {
        int W = ClientSize.Width, H = ClientSize.Height;
        _back.Visible = _step > 0;
        _back.Location = new Point(24, H - 56);
        _next.Location = new Point(W - 24 - _next.Width, H - 58);
        _skip.Location = new Point(W - 40, 12);
        bool last = _step == StepCount - 1;
        _launch.Visible = _launchLabel.Visible = last;
        _launchLabel.Location = new Point(40, H - 104);
        _launch.Location = new Point(W - 80, H - 108);
        UpdateNextLabel();
        Invalidate();
    }

    private void UpdateNextLabel()
    {
        if (_step < StepCount - 1) _next.Text = _zh ? "下一步" : "Next";
        else _next.Text = _app.EngineReady ? (_zh ? "开始使用" : "Get started") : (_zh ? "知道了" : "Got it");
        _next.Invalidate();
    }

    private void Dismiss()
    {
        _poll.Stop();
        _app.Settings.Welcomed = true;
        _app.Settings.Save();
        Close();
    }

    protected override CreateParams CreateParams
    {
        get { var cp = base.CreateParams; cp.ClassStyle |= 0x00020000; return cp; } // CS_DROPSHADOW
    }

    protected override void OnHandleCreated(EventArgs e)
    {
        base.OnHandleCreated(e);
        Region = new Region(Theme.RoundedRect(new RectangleF(0, 0, Width, Height), 18));
        Activate(); BringToFront();
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        var g = e.Graphics; Draw.Hq(g);
        int W = ClientSize.Width;
        Draw.StrokeRounded(g, new RectangleF(0, 0, W, Height), 18, Theme.Hairline);

        // Header: small logo + wordmark + subtitle + step dots.
        var logoRect = new RectangleF(28, 24, 34, 34);
        Draw.FillAccent(g, logoRect, 10);
        Draw.LogoBars(g, logoRect, new float[] { 8, 16, 22, 13, 9 }, 3f, 2.5f);
        TextRenderer.DrawText(g, "Vibe XASR", Theme.Ui(13f, FontStyle.Bold), new Rectangle(72, 25, 220, 22), Theme.Text, LeftMid);
        TextRenderer.DrawText(g, _zh ? "使用引导" : "Quick start", Theme.Ui(9f), new Rectangle(72, 45, 220, 16), Theme.TextMuted, LeftMid);
        for (int i = 0; i < StepCount; i++)
        {
            var col = i == _step ? Theme.AccentA : Theme.HairlineStrong;
            using var b = new SolidBrush(col);
            g.FillEllipse(b, W - 26 - (StepCount - i) * 15, 54, 7, 7);
        }

        switch (_step)
        {
            case 0: PaintWhere(g, W); break;
            case 1: PaintHow(g, W); break;
            default: PaintReady(g, W); break;
        }
    }

    // ---- Step 1: where it lives (bottom-right tray) ----
    private void PaintWhere(Graphics g, int W)
    {
        int y = 92;
        TextRenderer.DrawText(g, _zh ? "它在屏幕右下角的托盘里" : "It lives in the tray, bottom-right",
            Theme.Ui(15f, FontStyle.Bold), new Rectangle(28, y, W - 56, 26), Theme.Text, LeftTop); y += 34;
        string body = _zh
            ? "Vibe XASR 没有主窗口,装好后一直在后台待命。它的图标在任务栏最右侧的通知区(挨着时钟)。"
            : "Vibe XASR has no main window — it runs quietly in the background. Its icon sits in the notification area at the far right of the taskbar (next to the clock).";
        int bh = SettingsForm.MeasureWrapped(body, Theme.Ui(10.5f), W - 56);
        TextRenderer.DrawText(g, body, Theme.Ui(10.5f), new Rectangle(28, y, W - 56, bh), Theme.TextMuted, LeftTopWrap); y += bh + 14;

        // Mock taskbar strip with a highlighted tray cluster on the right.
        var bar = new RectangleF(28, y, W - 56, 56);
        Draw.FillRounded(g, bar, 10, Theme.Surface2);
        Draw.StrokeRounded(g, bar, 10, Theme.Hairline);
        float cy = bar.Y + bar.Height / 2f;
        // ⌃ overflow chevron + a couple of faint neighbour icons.
        float x = bar.Right - 188;
        TextRenderer.DrawText(g, "⌃", Theme.Ui(12f, FontStyle.Bold), new Rectangle((int)x, (int)bar.Y, 22, (int)bar.Height),
            Theme.TextMuted, CenterMid); x += 26;
        for (int i = 0; i < 2; i++) { using var b = new SolidBrush(Theme.HairlineStrong); g.FillEllipse(b, x, cy - 6, 12, 12); x += 22; }
        // The app icon, highlighted with a glowing accent ring.
        var tile = new RectangleF(x, cy - 13, 26, 26);
        for (int i = 3; i >= 1; i--) { using var gb = new SolidBrush(Color.FromArgb(26, Theme.AccentA)); float r = 13 + i * 3; g.FillEllipse(gb, tile.X + 13 - r, cy - r, r * 2, r * 2); }
        Draw.FillAccent(g, tile, 7);
        Draw.LogoBars(g, tile, new float[] { 6, 12, 16, 10, 7 }, 2.2f, 2f);
        x += 36;
        TextRenderer.DrawText(g, "12:30", Theme.Mono(8.5f), new Rectangle((int)x, (int)bar.Y, 56, (int)bar.Height), Theme.TextMuted, LeftMid);
        // Callout arrow under the tile.
        TextRenderer.DrawText(g, _zh ? "↑ 就在这里" : "↑ right here", Theme.Ui(9f, FontStyle.Bold),
            new Rectangle((int)tile.X - 30, (int)bar.Bottom + 4, 100, 16), Theme.AccentA, LeftTop);
        y += 56 + 26;

        string tip = _zh
            ? "💡 看不到图标?点通知区的 ⌃ 展开隐藏图标,把 Vibe XASR 拖到任务栏上即可一直显示。"
            : "💡 Don't see it? Click the ⌃ arrow to show hidden icons, then drag Vibe XASR onto the taskbar to keep it visible.";
        int th = SettingsForm.MeasureWrapped(tip, Theme.Ui(9.5f), W - 56);
        TextRenderer.DrawText(g, tip, Theme.Ui(9.5f), new Rectangle(28, y, W - 56, th), Theme.TextMuted, LeftTopWrap);
    }

    // ---- Step 2: how to use ----
    private void PaintHow(Graphics g, int W)
    {
        int y = 92;
        TextRenderer.DrawText(g, _zh ? "怎么用" : "How to use it",
            Theme.Ui(15f, FontStyle.Bold), new Rectangle(28, y, W - 56, 26), Theme.Text, LeftTop); y += 36;

        // The hotkey line: 按住 [Key] 说话 —— 松开落字
        var card = new RectangleF(28, y, W - 56, 70);
        Draw.FillRounded(g, card, 12, Theme.Surface2);
        Draw.StrokeRounded(g, card, 12, Theme.Hairline);
        string pre = _zh ? "按住 " : "Hold ", post = _zh ? " 说话" : " & speak";
        var f1 = Theme.Ui(13f, FontStyle.Bold);
        var preSz = TextRenderer.MeasureText(pre, f1);
        var keyF = Theme.Ui(11f, FontStyle.Bold);
        int keyW = TextRenderer.MeasureText(_keyName, keyF).Width + 20;
        var postSz = TextRenderer.MeasureText(post, f1);
        int totalW = preSz.Width + keyW + postSz.Width;
        int sx = (W - totalW) / 2, ly = (int)card.Y + 16;
        TextRenderer.DrawText(g, pre, f1, new Rectangle(sx, ly, preSz.Width, 24), Theme.Text, LeftMid);
        var keyRect = new RectangleF(sx + preSz.Width, ly + 1, keyW, 22);
        Draw.FillRounded(g, keyRect, 6, Theme.AccentSoft);
        Draw.StrokeRounded(g, keyRect, 6, Color.FromArgb(120, Theme.AccentA));
        TextRenderer.DrawText(g, _keyName, keyF, Rectangle.Round(keyRect), Theme.AccentA, CenterMid);
        TextRenderer.DrawText(g, post, f1, new Rectangle(sx + preSz.Width + keyW, ly, postSz.Width, 24), Theme.Text, LeftMid);
        TextRenderer.DrawText(g, _zh ? "松开 —— 识别的文字自动落到光标处" : "Release — the recognized text drops at your cursor",
            Theme.Ui(10f), new Rectangle((int)card.X + 12, ly + 28, (int)card.Width - 24, 20), Theme.TextMuted, CenterTop);
        y += 70 + 18;

        TextRenderer.DrawText(g, _zh ? "三种模式(右下角托盘菜单切换):" : "Three modes (switch in the tray menu, bottom-right):",
            Theme.Ui(10.5f, FontStyle.Bold), new Rectangle(28, y, W - 56, 20), Theme.Text, LeftTop); y += 26;
        (string t, string d)[] modes = _zh ? new[]
        {
            ("粘贴", "整句识别后一次性插入(推荐,最稳)"),
            ("逐字", "边说边出字 —— 微信里慎用,易被误检测"),
            ("持续候机", "常开免按键,结果显示在右上角悬浮窗"),
        } : new[]
        {
            ("Paste", "insert the whole sentence at once (recommended)"),
            ("Type", "types as you speak — avoid in WeChat (false-positives)"),
            ("OnCall", "always-on, hands-free; text shows in a top-right overlay"),
        };
        foreach (var (t, d) in modes)
        {
            using (var b = new SolidBrush(Theme.AccentB)) g.FillEllipse(b, 32, y + 6, 6, 6);
            int tw = TextRenderer.MeasureText(t, Theme.Ui(10.5f, FontStyle.Bold)).Width;
            TextRenderer.DrawText(g, t, Theme.Ui(10.5f, FontStyle.Bold), new Rectangle(46, y, tw + 4, 20), Theme.Text, LeftTop);
            TextRenderer.DrawText(g, d, Theme.Ui(9.5f), new Rectangle(46 + tw + 8, y, W - 56 - tw - 8 - 18, 20), Theme.TextMuted, LeftTop);
            y += 26;
        }
    }

    // ---- Step 3: live engine-ready status + mic + launch ----
    private void PaintReady(Graphics g, int W)
    {
        int y = 92;
        TextRenderer.DrawText(g, _zh ? "马上就好" : "Almost ready",
            Theme.Ui(15f, FontStyle.Bold), new Rectangle(28, y, W - 56, 26), Theme.Text, LeftTop); y += 38;

        bool ready = _app.EngineReady;
        var subFont = Theme.Ui(9.5f);
        string head = ready ? (_zh ? "识别引擎已就绪" : "Engine ready")
                            : (_zh ? "正在准备识别引擎…" : "Preparing the engine…");
        string sub = ready
            ? (_zh ? $"按住 {_keyName} 说话即可。" : $"Hold {_keyName} and speak.")
            : (_zh ? "首次启动要加载本地模型(约 560MB),通常几秒到十几秒,请稍候。" : "First launch loads the local model (~560MB) — usually a few seconds to ~15s.");
        int subW = W - 56 - 52;
        int subH = SettingsForm.MeasureWrapped(sub, subFont, subW);
        int cardH = Math.Max(60, 34 + subH + 12);
        var card = new RectangleF(28, y, W - 56, cardH);
        Draw.FillRounded(g, card, 12, ready ? SettingsForm.Blend(Theme.Success, Theme.Surface, 0.14f) : Theme.Surface2);
        Draw.StrokeRounded(g, card, 12, ready ? Color.FromArgb(120, Theme.Success) : Theme.Hairline);
        var dotC = ready ? Theme.Success : Theme.Warn;
        using (var b = new SolidBrush(dotC)) g.FillEllipse(b, (int)card.X + 16, (int)card.Y + 16, 12, 12);
        TextRenderer.DrawText(g, head, Theme.Ui(11.5f, FontStyle.Bold), new Rectangle((int)card.X + 40, (int)card.Y + 12, subW, 20), dotC, LeftTop);
        TextRenderer.DrawText(g, sub, subFont, new Rectangle((int)card.X + 40, (int)card.Y + 34, subW, subH), Theme.TextMuted, LeftTopWrap);
        y += cardH + 16;

        string mic = _app.MicGranted()
            ? (_zh ? "🎙 首次说话时若 Windows 询问麦克风权限,请点「允许」。" : "🎙 If Windows asks for microphone access on first use, click Allow.")
            : (_zh ? "⚠️ 麦克风似乎被禁用 —— 在 设置 › 权限 里开启,否则无法识别。" : "⚠️ Microphone seems blocked — enable it in Settings › Permissions.");
        int mh = SettingsForm.MeasureWrapped(mic, Theme.Ui(9.5f), W - 56);
        TextRenderer.DrawText(g, mic, Theme.Ui(9.5f), new Rectangle(28, y, W - 56, mh), _app.MicGranted() ? Theme.TextMuted : Theme.Warn, LeftTopWrap); y += mh + 12;

        TextRenderer.DrawText(g, _zh ? "🔒 100% 本地 · 离线 · 数据不出设备" : "🔒 100% local · offline · nothing leaves this device",
            Theme.Ui(9.5f), new Rectangle(28, y, W - 56, 18), Theme.TextMuted, LeftTop);
    }

    private const TextFormatFlags LeftMid = TextFormatFlags.Left | TextFormatFlags.VerticalCenter | TextFormatFlags.NoPadding;
    private const TextFormatFlags LeftTop = TextFormatFlags.Left | TextFormatFlags.Top | TextFormatFlags.NoPadding;
    private const TextFormatFlags LeftTopWrap = TextFormatFlags.Left | TextFormatFlags.Top | TextFormatFlags.WordBreak | TextFormatFlags.NoPadding;
    private const TextFormatFlags CenterMid = TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.NoPadding;
    private const TextFormatFlags CenterTop = TextFormatFlags.HorizontalCenter | TextFormatFlags.Top | TextFormatFlags.NoPadding;

    protected override void Dispose(bool disposing)
    {
        if (disposing) _poll.Dispose();
        base.Dispose(disposing);
    }
}
