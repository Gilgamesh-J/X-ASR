using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Text;
using System.Windows.Forms;

namespace VibeXASR.Windows.Ui;

/// <summary>
/// Drawing helpers + the two owner-drawn WinForms controls the shipping UI still uses
/// (<see cref="VibeToggle"/>, <see cref="VibeButton"/>) and the tray menu renderer.
///
/// Everything here reads colours from <see cref="Theme"/> — which is a reader of
/// <see cref="DesignTokens"/> — so one scheme switch repaints consistently and no control
/// carries a hex value of its own.
///
/// What used to live here and no longer does: RoundedPanel, LogoTile, SegmentedControl,
/// VibeSelect, VibeProgressBar and Draw.Circle. They were only ever constructed by the seven
/// WinForms screens replaced by the WPF ones, so they were 220 lines of unreachable code.
/// Re-add deliberately (and wire it to a real call site) rather than by copy-paste.
/// </summary>
internal static class Draw
{
    /// <summary>Fill a rounded rectangle with a solid color.</summary>
    public static void FillRounded(Graphics g, RectangleF r, float radius, Color fill)
    {
        if (fill.A == 0) return;
        var old = g.SmoothingMode;
        g.SmoothingMode = SmoothingMode.AntiAlias;
        using var p = Theme.RoundedRect(r, radius);
        using var b = new SolidBrush(fill);
        g.FillPath(b, p);
        g.SmoothingMode = old;
    }

    /// <summary>Stroke a rounded-rectangle border (inset by 0.5px for crisp 1px lines).</summary>
    public static void StrokeRounded(Graphics g, RectangleF r, float radius, Color stroke, float w = 1f)
    {
        if (stroke.A == 0 || w <= 0) return;
        var old = g.SmoothingMode;
        g.SmoothingMode = SmoothingMode.AntiAlias;
        var rr = RectangleF.Inflate(r, -w / 2f, -w / 2f);
        using var p = Theme.RoundedRect(rr, radius);
        using var pen = new Pen(stroke, w);
        g.DrawPath(pen, p);
        g.SmoothingMode = old;
    }

    /// <summary>Fill a rounded rect with the accent gradient.</summary>
    public static void FillAccent(Graphics g, RectangleF r, float radius)
    {
        var old = g.SmoothingMode;
        g.SmoothingMode = SmoothingMode.AntiAlias;
        using var p = Theme.RoundedRect(r, radius);
        var ri = Rectangle.Round(r);
        if (ri.Width <= 0) ri.Width = 1;
        if (ri.Height <= 0) ri.Height = 1;
        using var b = Theme.AccentBrush(ri);
        g.FillPath(b, p);
        g.SmoothingMode = old;
    }

    /// <summary>The white equalizer bars used in the logo tiles.</summary>
    public static void LogoBars(Graphics g, RectangleF host, float[] heights, float barW, float gap)
    {
        var old = g.SmoothingMode;
        g.SmoothingMode = SmoothingMode.AntiAlias;
        float total = heights.Length * barW + (heights.Length - 1) * gap;
        float x = host.X + (host.Width - total) / 2f;
        float cy = host.Y + host.Height / 2f;
        using var b = new SolidBrush(Color.White);
        foreach (var h in heights)
        {
            var rect = new RectangleF(x, cy - h / 2f, barW, h);
            using var p = Theme.RoundedRect(rect, barW / 2f);
            g.FillPath(b, p);
            x += barW + gap;
        }
        g.SmoothingMode = old;
    }


    /// <summary>Configure a Graphics for crisp text + shapes.</summary>
    public static void Hq(Graphics g)
    {
        g.SmoothingMode = SmoothingMode.AntiAlias;
        g.TextRenderingHint = TextRenderingHint.ClearTypeGridFit;
        g.InterpolationMode = InterpolationMode.HighQualityBicubic;
    }
}
/// <summary>The `.sw` switch: accent-gradient track when on, sliding white knob.</summary>
internal sealed class VibeToggle : Control
{
    private bool _on;
    public bool Checked
    {
        get => _on;
        set { if (_on != value) { _on = value; Invalidate(); CheckedChanged?.Invoke(this, EventArgs.Empty); } }
    }
    public event EventHandler? CheckedChanged;

    public VibeToggle()
    {
        DoubleBuffered = true;
        Size = new Size(42, 25);
        Cursor = Cursors.Hand;
        SetStyle(ControlStyles.SupportsTransparentBackColor, true);
        BackColor = Color.Transparent;
    }

    protected override void OnClick(EventArgs e) { Checked = !Checked; base.OnClick(e); }

    protected override void OnPaint(PaintEventArgs e)
    {
        var g = e.Graphics; Draw.Hq(g);
        var track = new RectangleF(0, (Height - 25) / 2f, 42, 25);
        if (_on) Draw.FillAccent(g, track, track.Height / 2f);
        else Draw.FillRounded(g, track, track.Height / 2f, Theme.ToggleTrack);
        float knob = 20f;
        float x = _on ? track.Right - knob - 2.5f : track.Left + 2.5f;
        var kr = new RectangleF(x, track.Top + (track.Height - knob) / 2f, knob, knob);
        using (var sh = new SolidBrush(Color.FromArgb(60, 0, 0, 0)))
            g.FillEllipse(sh, kr.X, kr.Y + 1, kr.Width, kr.Height);
        using var b = new SolidBrush(Color.White);
        g.FillEllipse(b, kr);
    }
}
/// <summary>Solid accent / ghost / danger button (`.m-btn`), rounded + flat.</summary>
internal sealed class VibeButton : Control
{
    public enum Kind { Solid, Ghost, Danger }
    public Kind Style { get; set; } = Kind.Solid;
    public float Radius { get; set; } = Theme.RadiusControl;
    private bool _hover;

    public VibeButton()
    {
        DoubleBuffered = true;
        Cursor = Cursors.Hand;
        Font = Theme.Ui(9.5f);
        Size = new Size(80, 30);
        SetStyle(ControlStyles.SupportsTransparentBackColor, true);
        BackColor = Color.Transparent;
    }

    protected override void OnMouseEnter(EventArgs e) { _hover = true; Invalidate(); base.OnMouseEnter(e); }
    protected override void OnMouseLeave(EventArgs e) { _hover = false; Invalidate(); base.OnMouseLeave(e); }

    protected override void OnPaint(PaintEventArgs e)
    {
        var g = e.Graphics; Draw.Hq(g);
        var r = new RectangleF(0, 0, Width, Height);
        Color fg, bg, border = Color.Transparent;
        switch (Style)
        {
            case Kind.Solid: fg = Color.White; bg = Theme.AccentFill; break;   // white on AccentFill = 5.40:1 (AccentA was 3.98)
            case Kind.Ghost: fg = Theme.Text; bg = Theme.Surface2; border = Theme.Hairline; break;
            default: fg = Theme.Error; bg = Color.Transparent; border = Theme.Hairline; break;
        }
        if (_hover && Style == Kind.Solid) bg = ControlPaint.Light(bg, 0.1f);
        if (_hover && Style == Kind.Danger) bg = Color.FromArgb(28, Theme.Error);
        if (_hover && Style == Kind.Ghost) bg = Theme.HairlineStrong;
        Draw.FillRounded(g, r, Radius, bg);
        if (border.A > 0) Draw.StrokeRounded(g, r, Radius, border);
        TextRenderer.DrawText(g, Text, Font, Rectangle.Round(r), fg,
            TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.NoPadding);
    }
}
/// <summary>Renderer for the tray's ContextMenuStrip: it pulls every menu colour from the token table,
/// so the menu follows the app's scheme instead of the OS's default blue/grey.</summary>
internal sealed class DarkMenuRenderer : ToolStripProfessionalRenderer
{
    public DarkMenuRenderer() : base(new DarkColors()) { RoundedEdges = true; }

    protected override void OnRenderItemText(ToolStripItemTextRenderEventArgs e)
    {
        e.TextColor = e.Item.Enabled ? Theme.Text : Theme.TextMuted;
        base.OnRenderItemText(e);
    }

    protected override void OnRenderArrow(ToolStripArrowRenderEventArgs e)
    {
        e.ArrowColor = Theme.TextMuted;
        base.OnRenderArrow(e);
    }

    private sealed class DarkColors : ProfessionalColorTable
    {
        public override Color MenuItemSelected => Theme.AccentSoft;
        public override Color MenuItemSelectedGradientBegin => Theme.AccentSoft;
        public override Color MenuItemSelectedGradientEnd => Theme.AccentSoft;
        public override Color MenuItemBorder => Theme.AccentA;
        public override Color MenuBorder => Theme.HairlineStrong;
        public override Color ToolStripDropDownBackground => Theme.Surface2;
        public override Color ImageMarginGradientBegin => Theme.Surface2;
        public override Color ImageMarginGradientMiddle => Theme.Surface2;
        public override Color ImageMarginGradientEnd => Theme.Surface2;
        public override Color SeparatorDark => Theme.Hairline;
        public override Color SeparatorLight => Theme.Hairline;
        public override Color CheckBackground => Theme.AccentSoft;
        public override Color CheckSelectedBackground => Theme.AccentSoft;
    }
}