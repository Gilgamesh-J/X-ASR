using System;
using System.Drawing;
using System.Linq;
using System.Windows.Forms;

namespace VibeXASR.Windows.Ui;

/// <summary>
/// The macOS-style menu-bar dropdown, recreated as a borderless rounded popup shown when
/// the tray icon is left-clicked — a port of <c>MenuBarContentView.swift</c>: a status row
/// (colored dot + state + sub), the most-recent card, an "Enable dictation" toggle, and
/// Settings / History / Quit entries. Closes when it loses focus.
/// </summary>
public sealed class TrayPopupForm : Form
{
    private readonly IAppController _app;
    private const int W = 300;

    private readonly VibeToggle _enable = new();
    private readonly System.Windows.Forms.Timer _pulse = new() { Interval = 60 };
    private float _ping;

    public TrayPopupForm(IAppController app)
    {
        _app = app;
        FormBorderStyle = FormBorderStyle.None;
        ShowInTaskbar = false;
        StartPosition = FormStartPosition.Manual;
        DoubleBuffered = true;
        BackColor = Theme.Surface;
        TopMost = true;
        Width = W;
        Font = Theme.Ui(9.5f);

        _enable.CheckedChanged += (_, _) => _app.DictationEnabled = _enable.Checked;
        Controls.Add(_enable);

        _pulse.Tick += (_, _) => { _ping += 0.05f; if (_ping > 1) _ping = 0; if (_app.IsListening) Invalidate(); };
        _pulse.Start();
        // Close on focus loss like a real menu — except under the VIBEXASR_OPEN=popup test
        // hook, where it stays pinned so it can be inspected/captured.
        Deactivate += (_, _) =>
        {
            if (Environment.GetEnvironmentVariable("VIBEXASR_OPEN") != "popup") Hide();
        };
    }

    protected override CreateParams CreateParams
    {
        get
        {
            var cp = base.CreateParams;
            cp.ExStyle |= 0x00000080;   // WS_EX_TOOLWINDOW (no taskbar button)
            cp.ClassStyle |= 0x00020000; // CS_DROPSHADOW (soft floating shadow)
            return cp;
        }
    }

    /// <summary>Position above the notification area and show (activated, so it self-closes).</summary>
    public void ShowNear()
    {
        Rebuild();
        var wa = Screen.PrimaryScreen!.WorkingArea;
        Location = new Point(wa.Right - Width - 12, wa.Bottom - Height - 12);
        Region = new Region(Theme.RoundedRect(new RectangleF(0, 0, Width, Height), 14));
        Show();
        Activate();
        BringToFront();
    }

    private void Rebuild()
    {
        Controls.Clear();
        Controls.Add(_enable);

        bool listening = _app.IsListening;

        // recent card area height depends on text
        string recent = listening ? _app.CurrentOverlayText
                                   : (_app.History.List().FirstOrDefault()?.Text ?? "");
        int cardTextW = W - 32 - 24;
        int cardH = Math.Max(36, SettingsForm.MeasureWrapped(
            string.IsNullOrEmpty(recent) ? "—" : recent, Theme.Mono(9f), cardTextW) + 20);
        int recentBlock = 7 + 14 + 7 + cardH + 12; // label + gap + card + padding

        // Place the enable toggle.
        int enableRowY = 14 + 38 + 1 + recentBlock + 1 + 11;
        _enable.Location = new Point(W - 16 - _enable.Width, enableRowY);

        // Entry rows.
        int entriesY = enableRowY + 25 + 11 + 1 + 6;
        AddEntry("⚙", L10n.T("menu.settings"), entriesY, false, () => { Hide(); _app.OpenSettings(); });
        AddEntry("🗂", L10n.T("menu.history"), entriesY + 34, false, () => { Hide(); _app.OpenHistory(); });
        AddEntry("⏻", L10n.T("menu.quit"), entriesY + 68, true, () => _app.Quit());

        Height = entriesY + 68 + 34 + 6;
        _enable.Checked = _app.DictationEnabled;
        Invalidate();
    }

    private void AddEntry(string icon, string text, int y, bool destructive, Action onClick)
    {
        var row = new MenuEntryRow(icon, text, destructive) { Location = new Point(6, y), Width = W - 12, Height = 32 };
        row.Clicked += onClick;
        Controls.Add(row);
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        var g = e.Graphics; Draw.Hq(g);
        Draw.FillRounded(g, new RectangleF(0, 0, Width, Height), 14, Theme.Surface);
        Draw.StrokeRounded(g, new RectangleF(0, 0, Width, Height), 14, Theme.Hairline);

        bool listening = _app.IsListening;
        bool ready = _app.EngineReady;

        // Status row: dot + state + sub.
        Color dotColor = !ready ? Theme.Warn : listening ? Theme.AccentA : Theme.Success;
        float dx = 22, dy = 25;
        if (listening)
        {
            using var ring = new Pen(Color.FromArgb((int)(120 * (1 - _ping)), Theme.AccentA), 2f);
            float rr = 5 + _ping * 9;
            g.DrawEllipse(ring, dx - rr, dy - rr, rr * 2, rr * 2);
        }
        using (var b = new SolidBrush(dotColor)) g.FillEllipse(b, dx - 4.5f, dy - 4.5f, 9, 9);

        string state = !ready ? L10n.T("menu.loading") : listening ? L10n.T("menu.listening") : L10n.T("menu.ready");
        TextRenderer.DrawText(g, state, Theme.Ui(10.5f, FontStyle.Bold), new Rectangle(38, 12, W - 50, 18),
            Theme.Text, TextFormatFlags.Left | TextFormatFlags.NoPadding);
        TextRenderer.DrawText(g, "X-ASR · " + (L10n.Resolved == Lang.Zh ? "本地" : "local"),
            Theme.Mono(8f), new Rectangle(38, 31, W - 50, 16), Theme.TextMuted,
            TextFormatFlags.Left | TextFormatFlags.NoPadding);

        int y = 14 + 38;
        Separator(g, y); y += 1;

        // Most-recent.
        y += 12;
        TextRenderer.DrawText(g, L10n.T("menu.recent"), Theme.Mono(7.5f), new Rectangle(16, y, W - 32, 14),
            Theme.TextMuted, TextFormatFlags.Left | TextFormatFlags.NoPadding);
        y += 18;
        string recent = listening ? _app.CurrentOverlayText
                                   : (_app.History.List().FirstOrDefault()?.Text ?? "");
        int cardTextW = W - 32 - 24;
        int cardH = Math.Max(36, SettingsForm.MeasureWrapped(
            string.IsNullOrEmpty(recent) ? "—" : recent, Theme.Mono(9f), cardTextW) + 20);
        var card = new RectangleF(16, y, W - 32, cardH);
        Draw.FillRounded(g, card, 9, Theme.Surface2);
        Draw.StrokeRounded(g, card, 9, Theme.Hairline);
        var shown = string.IsNullOrEmpty(recent)
            ? (L10n.Resolved == Lang.Zh ? "（暂无）" : "(none)") : recent;
        TextRenderer.DrawText(g, shown, Theme.Mono(9f),
            new Rectangle(28, (int)y + 10, cardTextW, cardH - 20),
            string.IsNullOrEmpty(recent) ? Theme.TextMuted : Theme.Text,
            TextFormatFlags.Left | TextFormatFlags.Top | TextFormatFlags.WordBreak | TextFormatFlags.NoPadding);
        if (listening && !string.IsNullOrEmpty(recent) && _ping < 0.5f)
        {
            int tw = Math.Min(cardTextW, TextRenderer.MeasureText(shown, Theme.Mono(9f)).Width);
            TextRenderer.DrawText(g, "▌", Theme.Mono(9f), new Rectangle(28 + tw, (int)y + 10, 14, 18),
                Theme.AccentB, TextFormatFlags.Left | TextFormatFlags.NoPadding);
        }
        y += cardH + 12;
        Separator(g, y); y += 1;

        // Enable row label (toggle is a child control positioned in Rebuild).
        y += 11;
        TextRenderer.DrawText(g, L10n.T("menu.enable"), Theme.Ui(10f), new Rectangle(16, y, W - 80, 20),
            Theme.Text, TextFormatFlags.Left | TextFormatFlags.VerticalCenter | TextFormatFlags.NoPadding);
        y += 25 + 11;
        Separator(g, y);
    }

    private static void Separator(Graphics g, int y)
    {
        using var pen = new Pen(Theme.Hairline);
        g.DrawLine(pen, 12, y, W - 12, y);
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing) _pulse.Dispose();
        base.Dispose(disposing);
    }
}

/// <summary>A `.entry` row in the tray popup: icon + label, hover highlight, red on hover if destructive.</summary>
internal sealed class MenuEntryRow : Control
{
    private readonly string _icon, _text;
    private readonly bool _destructive;
    private bool _hover;
    public event Action? Clicked;

    public MenuEntryRow(string icon, string text, bool destructive)
    {
        _icon = icon; _text = text; _destructive = destructive;
        DoubleBuffered = true; Cursor = Cursors.Hand;
        Font = Theme.Ui(10f);
        SetStyle(ControlStyles.SupportsTransparentBackColor, true);
        BackColor = Color.Transparent;
    }

    protected override void OnMouseEnter(EventArgs e) { _hover = true; Invalidate(); base.OnMouseEnter(e); }
    protected override void OnMouseLeave(EventArgs e) { _hover = false; Invalidate(); base.OnMouseLeave(e); }
    protected override void OnClick(EventArgs e) { Clicked?.Invoke(); base.OnClick(e); }

    protected override void OnPaint(PaintEventArgs e)
    {
        var g = e.Graphics; Draw.Hq(g);
        var color = _destructive && _hover ? Theme.Error : Theme.Text;
        if (_hover)
            Draw.FillRounded(g, new RectangleF(0, 0, Width, Height), Theme.RadiusControl,
                _destructive ? Color.FromArgb(41, Theme.Error) : Theme.AccentSoft);
        TextRenderer.DrawText(g, _icon, Theme.Ui(11f), new Rectangle(10, 0, 22, Height), color,
            TextFormatFlags.Left | TextFormatFlags.VerticalCenter | TextFormatFlags.NoPadding);
        TextRenderer.DrawText(g, _text, Font, new Rectangle(38, 0, Width - 48, Height), color,
            TextFormatFlags.Left | TextFormatFlags.VerticalCenter | TextFormatFlags.NoPadding);
    }
}
