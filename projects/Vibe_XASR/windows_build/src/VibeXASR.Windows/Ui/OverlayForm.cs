using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Runtime.InteropServices;
using System.Windows.Forms;

namespace VibeXASR.Windows.Ui;

/// <summary>
/// Borderless, top-most, never-activating overlay — the Windows port of the macOS
/// HUD pill + OnCall panel. Two visual states:
///  • HUD (push-to-talk): a rounded glass pill near the bottom centre with an accent
///    orb, a center-weighted reactive waveform, the streaming mono text + blinking
///    caret, and an elapsed timer. Click-through so the target app keeps focus/clicks.
///  • OnCall: a top-right panel with a red dot + "OnCall" + timer, the live transcript,
///    and Copy / View / Pause / Stop pills (interactive).
/// </summary>
public sealed class OverlayForm : Form
{
    public enum OverlayState { Hidden, Listening, Inserted, OnCall }

    private OverlayState _state = OverlayState.Hidden;
    private string _text = string.Empty;
    private double _level;                 // 0..1 mic envelope (drives the waveform)
    private DateTime _startedAt = DateTime.Now;
    private bool _paused;

    private readonly double[] _bars = new double[20];
    private readonly Random _rng = new();
    private readonly System.Windows.Forms.Timer _anim = new() { Interval = 45 };
    private int _blinkTick;

    // OnCall action pills.
    private readonly PillButton _copy, _view, _pause, _stop;

    public event EventHandler? CopyRequested;
    public event EventHandler? StopRequested;
    public event EventHandler? ViewRequested;
    public event EventHandler? PauseRequested;

    /// <summary>Live overlay text (used by the tray "recent" + copy).</summary>
    public string CurrentText => _text;

    public OverlayForm()
    {
        FormBorderStyle = FormBorderStyle.None;
        ShowInTaskbar = false;
        TopMost = true;
        StartPosition = FormStartPosition.Manual;
        DoubleBuffered = true;
        BackColor = Theme.IsDark ? Theme.Hex("#15151B") : Theme.Hex("#FFFFFF");
        // We always carry WS_EX_LAYERED (needed for click-through). Setting Opacity makes
        // WinForms configure the layered alpha so GDI content actually composites/shows;
        // without it a bare layered window can render invisible.
        Opacity = 0.97;
        Size = new Size(560, 64);

        _copy = new PillButton(() => L10n.T("copy"));
        _view = new PillButton(() => L10n.T("history.title"));
        _pause = new PillButton(() => _paused ? "▶" : "❚❚");
        _stop = new PillButton(() => L10n.T("hud.stop")) { Filled = true };
        _copy.Click += (_, _) => CopyRequested?.Invoke(this, EventArgs.Empty);
        _view.Click += (_, _) => ViewRequested?.Invoke(this, EventArgs.Empty);
        _pause.Click += (_, _) => { _paused = !_paused; PauseRequested?.Invoke(this, EventArgs.Empty); Invalidate(); };
        _stop.Click += (_, _) => StopRequested?.Invoke(this, EventArgs.Empty);
        foreach (var p in new[] { _copy, _view, _pause, _stop }) { p.Visible = false; Controls.Add(p); }

        _anim.Tick += (_, _) => OnAnimTick();
        for (int i = 0; i < _bars.Length; i++) _bars[i] = 0.08;
    }

    // ---- public driving API (called from TrayApp on the UI thread) ----

    public void SetLevel(double level)
    {
        _level = Math.Max(0, Math.Min(1, level));
    }

    public void SetText(string text)
    {
        if (InvokeRequired) { BeginInvoke(() => SetText(text)); return; }
        _text = text ?? string.Empty;
        Invalidate();
    }

    /// <summary>Enter the transient push-to-talk HUD (click-through).</summary>
    public void ShowListening()
    {
        if (InvokeRequired) { BeginInvoke(ShowListening); return; }
        _state = OverlayState.Listening;
        _text = string.Empty;
        _startedAt = DateTime.Now;
        Size = new Size(560, 64);
        SetButtonsVisible(false);
        ApplyClickThrough(true);
        ApplyRoundedRegion(Height / 2f);
        PositionBottomCenter();
        _anim.Start();
        ShowNoActivate();
    }

    /// <summary>Briefly show a compact "已插入 · N 字" confirmation, then hide.
    /// (autoHide=false keeps it up — used by the VIBEXASR_OPEN=overlay:inserted debug hook.)</summary>
    public void ShowInserted(bool autoHide = true)
    {
        if (InvokeRequired) { BeginInvoke(() => ShowInserted(autoHide)); return; }
        if (_state == OverlayState.OnCall) return;
        _state = OverlayState.Inserted;
        // Shrink the pill to fit the confirmation (no truncated text echo) — like macOS fixedSize.
        int tw = TextRenderer.MeasureText(L10n.T("hud.insertedN", CharCount(_text)), Theme.Ui(11.5f, FontStyle.Bold)).Width;
        Size = new Size(Math.Max(190, 48 + tw + 22), 56);
        ApplyRoundedRegion(Height / 2f);
        PositionBottomCenter();
        Invalidate();
        if (!autoHide) return;
        var t = new System.Windows.Forms.Timer { Interval = 1100 };
        t.Tick += (_, _) => { t.Stop(); t.Dispose(); HideOverlay(); };
        t.Start();
    }

    /// <summary>Enter the persistent OnCall panel (top-right, interactive).</summary>
    public void ShowOnCall()
    {
        if (InvokeRequired) { BeginInvoke(ShowOnCall); return; }
        _state = OverlayState.OnCall;
        _text = string.Empty;
        _paused = false;
        _startedAt = DateTime.Now;
        Size = new Size(340, 196);
        ApplyClickThrough(false);
        ApplyRoundedRegion(16);
        SetButtonsVisible(true);
        LayoutOnCallButtons();
        PositionTopRight();
        _anim.Start();
        ShowNoActivate();
    }

    public void HideOverlay()
    {
        if (InvokeRequired) { BeginInvoke(HideOverlay); return; }
        if (_state == OverlayState.OnCall) return; // OnCall stays until Stop
        _state = OverlayState.Hidden;
        _anim.Stop();
        Hide();
    }

    /// <summary>Leave OnCall explicitly (called when the mode changes away from OnCall).</summary>
    public void LeaveOnCall()
    {
        if (InvokeRequired) { BeginInvoke(LeaveOnCall); return; }
        _state = OverlayState.Hidden;
        _anim.Stop();
        SetButtonsVisible(false);
        Hide();
    }

    // ---- animation ----

    private void OnAnimTick()
    {
        _blinkTick++;
        bool speaking = _state is OverlayState.Listening or OverlayState.OnCall && !_paused;
        double mid = (_bars.Length - 1) / 2.0;
        for (int i = 0; i < _bars.Length; i++)
        {
            double c = 1 - Math.Abs(i - mid) / Math.Max(mid, 0.0001);
            double env = 0.35 + 0.65 * c;
            double target = speaking
                ? Math.Max(0.08, _level * env * (0.5 + _rng.NextDouble() * 0.7))
                : 0.07 + _rng.NextDouble() * 0.02;
            _bars[i] += (target - _bars[i]) * 0.35;
            _bars[i] = Math.Min(1, Math.Max(0.05, _bars[i]));
        }
        // Gentle level decay so the bars settle if frames stop arriving.
        _level *= 0.85;
        Invalidate();
    }

    private string Elapsed()
    {
        var s = (int)(DateTime.Now - _startedAt).TotalSeconds;
        return $"{s / 60}:{s % 60:00}";
    }

    /// <summary>Character count of the inserted text (for the "已插入 · N 字" confirmation).</summary>
    private static int CharCount(string? s) => string.IsNullOrEmpty(s) ? 0 : s.Trim().Length;

    /// <summary>Truncate from the HEAD with a leading "…" so the NEWEST words stay visible as the
    /// stream grows (GDI has no head-ellipsis flag; macOS uses .truncationMode(.head)).
    /// Binary-search the smallest tail that still fits in <paramref name="maxW"/>.</summary>
    private static string ClipHead(string s, Font f, int maxW)
    {
        if (string.IsNullOrEmpty(s) || maxW <= 0) return s ?? string.Empty;
        if (TextRenderer.MeasureText(s, f).Width <= maxW) return s;
        int lo = 1, hi = s.Length - 1, best = s.Length - 1;
        while (lo <= hi)
        {
            int mid = (lo + hi) / 2;
            if (TextRenderer.MeasureText("…" + s.Substring(mid), f).Width <= maxW) { best = mid; hi = mid - 1; }
            else lo = mid + 1;
        }
        return "…" + s.Substring(best);
    }

    // ---- paint ----

    protected override void OnPaint(PaintEventArgs e)
    {
        var g = e.Graphics; Draw.Hq(g);
        var bg = Theme.IsDark ? Theme.Hex("#15151B") : Theme.Hex("#FFFFFF");
        if (_state == OverlayState.OnCall) PaintOnCall(g, bg);
        else PaintHud(g, bg);
    }

    private void PaintHud(Graphics g, Color bg)
    {
        bool done = _state == OverlayState.Inserted;
        var r = new RectangleF(0.75f, 0.75f, Width - 1.5f, Height - 1.5f);
        float rad = Height / 2f;
        Draw.FillRounded(g, r, rad, bg);
        // Soft glowing edge — accent while listening, green when inserted.
        var edge = done ? Theme.Success : Theme.AccentA;
        Draw.StrokeRounded(g, r, rad, Color.FromArgb(70, edge), 3f);
        Draw.StrokeRounded(g, r, rad, Color.FromArgb(done ? 200 : 150, edge), 1.4f);

        // Inserted: a clean compact confirmation — green ✓ orb + "已插入 · N 字" (no truncated echo).
        if (done)
        {
            PaintOrb(g, new PointF(28, Height / 2f), 12, true);
            TextRenderer.DrawText(g, L10n.T("hud.insertedN", CharCount(_text)),
                Theme.Ui(11.5f, FontStyle.Bold), new Rectangle(48, 0, Width - 48 - 14, Height),
                Theme.Success, TextFormatFlags.Left | TextFormatFlags.VerticalCenter | TextFormatFlags.NoPadding);
            return;
        }

        // Listening: center-weighted waveform behind a glowing accent orb.
        if (_state == OverlayState.Listening) PaintWaveform(g, new RectangleF(20, Height / 2f - 13, 40, 26));
        PaintOrb(g, new PointF(40, Height / 2f), 13, false);

        // Right: elapsed-timer pill.
        var rf = Theme.Mono(9.5f);
        string right = Elapsed();
        var rsz = TextRenderer.MeasureText(right, rf);
        int rightX = Width - rsz.Width - 20;
        Draw.FillRounded(g, new RectangleF(rightX - 9, Height / 2f - 11, rsz.Width + 18, 22), 11, Theme.Surface2);
        TextRenderer.DrawText(g, right, rf, new Rectangle(rightX, 0, rsz.Width, Height), Theme.TextMuted,
            TextFormatFlags.Left | TextFormatFlags.VerticalCenter | TextFormatFlags.NoPadding);

        // Middle: streaming text. Empty → prompt; else the line truncated from the HEAD so the
        // NEWEST words stay visible (matches macOS .truncationMode(.head)), with a blinking caret.
        int midX = 70, midW = rightX - 16 - midX;
        var mf = Theme.Mono(11.5f);
        if (_text.Length == 0)
        {
            bool zh = L10n.Resolved == Lang.Zh;
            TextRenderer.DrawText(g, L10n.T("hud.listening"), mf, new Rectangle(midX, 0, midW, Height),
                Theme.Text, TextFormatFlags.Left | TextFormatFlags.VerticalCenter | TextFormatFlags.NoPadding);
            int lw = TextRenderer.MeasureText(L10n.T("hud.listening"), mf).Width;
            TextRenderer.DrawText(g, zh ? "松开落字" : "release to insert", Theme.Ui(9f),
                new Rectangle(midX + lw + 10, 0, midW - lw - 10, Height), Theme.TextMuted,
                TextFormatFlags.Left | TextFormatFlags.VerticalCenter | TextFormatFlags.NoPadding);
        }
        else
        {
            string shown = ClipHead(_text, mf, midW - 14);
            int tw = Math.Min(midW, TextRenderer.MeasureText(shown, mf).Width);
            TextRenderer.DrawText(g, shown, mf, new Rectangle(midX, 0, midW, Height), Theme.Text,
                TextFormatFlags.Left | TextFormatFlags.VerticalCenter | TextFormatFlags.NoPadding);
            if (_blinkTick % 16 < 8)
                TextRenderer.DrawText(g, "▌", mf, new Rectangle(midX + tw, 0, 16, Height), Theme.AccentB,
                    TextFormatFlags.Left | TextFormatFlags.VerticalCenter | TextFormatFlags.NoPadding);
        }
    }

    private void PaintOnCall(Graphics g, Color bg)
    {
        var r = new RectangleF(0, 0, Width, Height);
        Draw.FillRounded(g, r, 16, bg);
        Draw.StrokeRounded(g, r, 16, Theme.Hairline);

        // Header: red dot · OnCall · elapsed.
        using (var b = new SolidBrush(Theme.Error)) g.FillEllipse(b, 14, 16, 8, 8);
        TextRenderer.DrawText(g, "OnCall", Theme.Ui(9.5f, FontStyle.Bold), new Rectangle(28, 11, 120, 18),
            Theme.Text, TextFormatFlags.Left | TextFormatFlags.NoPadding);
        var el = Elapsed();
        TextRenderer.DrawText(g, el, Theme.Mono(8.5f),
            new Rectangle(Width - 70, 11, 56, 18), Theme.TextMuted,
            TextFormatFlags.Right | TextFormatFlags.NoPadding);

        // Body transcript.
        string body = _paused ? "❚❚ " + (L10n.Resolved == Lang.Zh ? "已暂停" : "Paused")
                    : (_text.Length == 0
                       ? (L10n.Resolved == Lang.Zh ? "候机中,识别到说话即显示…" : "Standby — speak to capture…")
                       : _text);
        TextRenderer.DrawText(g, body, Theme.Mono(10f), new Rectangle(14, 38, Width - 28, 100),
            _text.Length == 0 ? Theme.TextMuted : Theme.Text,
            TextFormatFlags.Left | TextFormatFlags.Top | TextFormatFlags.WordBreak | TextFormatFlags.NoPadding);
    }

    private void PaintWaveform(Graphics g, RectangleF area)
    {
        int n = _bars.Length;
        float barW = 2, gap = 2;
        float total = n * barW + (n - 1) * gap;
        float x = area.X + (area.Width - total) / 2f;
        var rect = Rectangle.Round(area);
        using var brush = new LinearGradientBrush(rect, Theme.AccentA, Theme.AccentB, LinearGradientMode.Vertical);
        foreach (var h in _bars)
        {
            float bh = Math.Max(2, (float)h * area.Height);
            var br = new RectangleF(x, area.Y + (area.Height - bh) / 2f, barW, bh);
            using var p = Theme.RoundedRect(br, barW / 2f);
            g.FillPath(brush, p);
            x += barW + gap;
        }
    }

    private void PaintOrb(Graphics g, PointF c, float radius, bool done)
    {
        // Soft glow halo (pulses gently with mic level while listening).
        var glow = done ? Theme.Success : Theme.AccentA;
        float pulse = done ? 1f : (float)(1.0 + 0.6 * Math.Min(1.0, _level));
        for (int i = 3; i >= 1; i--)
        {
            float gr = radius + i * 5f * pulse;
            using var gb = new SolidBrush(Color.FromArgb(done ? 26 : 22, glow));
            g.FillEllipse(gb, c.X - gr, c.Y - gr, gr * 2, gr * 2);
        }

        var rect = new RectangleF(c.X - radius, c.Y - radius, radius * 2, radius * 2);
        if (done)
        {
            using var b = new SolidBrush(Theme.Success);
            g.FillEllipse(b, rect);
            TextRenderer.DrawText(g, "✓", Theme.Ui(11f, FontStyle.Bold), Rectangle.Round(rect), Color.White,
                TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.NoPadding);
        }
        else
        {
            using var b = Theme.AccentBrush(Rectangle.Round(rect));
            g.FillEllipse(b, rect);
            // subtle top highlight
            using var hl = new SolidBrush(Color.FromArgb(60, 255, 255, 255));
            g.FillEllipse(hl, c.X - radius * 0.5f, c.Y - radius * 0.7f, radius, radius * 0.7f);
        }
    }

    // ---- OnCall button layout ----

    private void SetButtonsVisible(bool on)
    {
        foreach (var p in new[] { _copy, _view, _pause, _stop }) p.Visible = on;
    }

    private void LayoutOnCallButtons()
    {
        int y = Height - 40;
        int x = 14;
        foreach (var p in new[] { _copy, _view, _pause, _stop })
        {
            p.Recalc();
            p.Location = new Point(x, y);
            x += p.Width + 7;
        }
    }

    // ---- positioning ----

    public void PositionBottomCenter()
    {
        var wa = Screen.PrimaryScreen!.WorkingArea;
        Location = new Point(wa.Left + (wa.Width - Width) / 2, wa.Bottom - Height - 80);
    }

    public void PositionTopRight()
    {
        var wa = Screen.PrimaryScreen!.WorkingArea;
        Location = new Point(wa.Right - Width - 24, wa.Top + 24);
    }

    // ---- never-activate / click-through window styles ----

    private const int GWL_EXSTYLE = -20;
    private const int WS_EX_NOACTIVATE = 0x08000000;
    private const int WS_EX_TOOLWINDOW = 0x00000080;
    private const int WS_EX_LAYERED = 0x00080000;
    private const int WS_EX_TRANSPARENT = 0x00000020;
    private const int WS_EX_TOPMOST = 0x00000008;
    private static readonly IntPtr HWND_TOPMOST = new(-1);
    private const uint SWP_NOACTIVATE = 0x0010, SWP_NOMOVE = 0x0002, SWP_NOSIZE = 0x0001;

    private bool _clickThrough;

    protected override CreateParams CreateParams
    {
        get
        {
            var cp = base.CreateParams;
            cp.ExStyle |= WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW | WS_EX_TOPMOST | WS_EX_LAYERED;
            if (_clickThrough) cp.ExStyle |= WS_EX_TRANSPARENT;
            return cp;
        }
    }

    protected override bool ShowWithoutActivation => true;

    private void ApplyClickThrough(bool on)
    {
        _clickThrough = on;
        if (IsHandleCreated)
        {
            long ex = GetWindowLongPtr(Handle, GWL_EXSTYLE).ToInt64();
            if (on) ex |= WS_EX_TRANSPARENT; else ex &= ~WS_EX_TRANSPARENT;
            SetWindowLongPtr(Handle, GWL_EXSTYLE, new IntPtr(ex));
        }
    }

    private void ApplyRoundedRegion(float radius)
    {
        if (Width <= 0 || Height <= 0) return;
        Region = new Region(Theme.RoundedRect(new RectangleF(0, 0, Width, Height), radius));
    }

    private void ShowNoActivate()
    {
        if (!Visible) Visible = true;
        const int SW_SHOWNOACTIVATE = 4;
        ShowWindow(Handle, SW_SHOWNOACTIVATE);
        SetWindowPos(Handle, HWND_TOPMOST, Left, Top, Width, Height, SWP_NOACTIVATE | SWP_NOMOVE | SWP_NOSIZE);
    }

    // GetWindowLongPtr/SetWindowLongPtr: correct 64-bit variants (the int GetWindowLong
    // truncates the extended-style word on x64). On 32-bit these thunk to GetWindowLong.
    [DllImport("user32.dll", EntryPoint = "GetWindowLongPtr", SetLastError = true)]
    private static extern IntPtr GetWindowLongPtr(IntPtr hWnd, int nIndex);
    [DllImport("user32.dll", EntryPoint = "SetWindowLongPtr", SetLastError = true)]
    private static extern IntPtr SetWindowLongPtr(IntPtr hWnd, int nIndex, IntPtr dwNewLong);
    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter,
        int X, int Y, int cx, int cy, uint uFlags);

    protected override void Dispose(bool disposing)
    {
        if (disposing) _anim.Dispose();
        base.Dispose(disposing);
    }
}

/// <summary>A small rounded action pill used by the OnCall overlay.</summary>
internal sealed class PillButton : Control
{
    private readonly Func<string> _label;
    public bool Filled { get; set; }
    private bool _hover;

    public PillButton(Func<string> label)
    {
        _label = label;
        DoubleBuffered = true; Cursor = Cursors.Hand;
        Font = Theme.Ui(9.5f, FontStyle.Bold);
        Height = 28;
        SetStyle(ControlStyles.SupportsTransparentBackColor, true);
        BackColor = Color.Transparent;
    }

    protected override void OnMouseEnter(EventArgs e) { _hover = true; Invalidate(); base.OnMouseEnter(e); }
    protected override void OnMouseLeave(EventArgs e) { _hover = false; Invalidate(); base.OnMouseLeave(e); }

    /// <summary>Recompute width from the (possibly re-localized) label. Call before layout.</summary>
    public void Recalc() => Width = Math.Max(44, TextRenderer.MeasureText(_label(), Font).Width + 24);

    protected override void OnPaint(PaintEventArgs e)
    {
        var g = e.Graphics; Draw.Hq(g);
        string text = _label();
        var r = new RectangleF(0, 0, Width, Height);
        var fill = Filled ? Theme.Error : Theme.Surface2;
        if (_hover) fill = Filled ? ControlPaint.Light(Theme.Error, 0.1f) : Theme.HairlineStrong;
        Draw.FillRounded(g, r, Height / 2f, fill);
        TextRenderer.DrawText(g, text, Font, Rectangle.Round(r), Filled ? Color.White : Theme.Text,
            TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.NoPadding);
    }
}
