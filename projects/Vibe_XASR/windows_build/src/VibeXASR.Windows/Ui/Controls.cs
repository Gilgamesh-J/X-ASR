using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Text;
using System.Windows.Forms;

namespace VibeXASR.Windows.Ui;

/// <summary>
/// Reusable owner-drawn WinForms controls that reproduce the macOS app's design
/// language (glass-ish dark surfaces, the purple→teal accent gradient, rounded
/// cards, segmented pills, toggles). Everything here reads colors from
/// <see cref="Theme"/> so a single dark/light switch repaints consistently.
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

    public static GraphicsPath Circle(float cx, float cy, float r)
    {
        var p = new GraphicsPath();
        p.AddEllipse(cx - r, cy - r, r * 2, r * 2);
        return p;
    }

    /// <summary>Configure a Graphics for crisp text + shapes.</summary>
    public static void Hq(Graphics g)
    {
        g.SmoothingMode = SmoothingMode.AntiAlias;
        g.TextRenderingHint = TextRenderingHint.ClearTypeGridFit;
        g.InterpolationMode = InterpolationMode.HighQualityBicubic;
    }
}

/// <summary>A double-buffered panel that paints a rounded surface + optional border.</summary>
internal class RoundedPanel : Panel
{
    public Color Fill { get; set; } = Theme.Surface;
    public Color Border { get; set; } = Color.Transparent;
    public float Radius { get; set; } = Theme.RadiusCard;
    public float BorderWidth { get; set; } = 1f;
    /// <summary>Clip child controls to the rounded shape (so card corners are clean).</summary>
    public bool ClipToRound { get; set; }

    public RoundedPanel()
    {
        DoubleBuffered = true;
        SetStyle(ControlStyles.SupportsTransparentBackColor, true);
        BackColor = Color.Transparent;
    }

    protected override void OnSizeChanged(EventArgs e)
    {
        base.OnSizeChanged(e);
        if (ClipToRound && Width > 0 && Height > 0)
            Region = new Region(Theme.RoundedRect(new RectangleF(0, 0, Width, Height), Radius));
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        Draw.Hq(e.Graphics);
        var r = new RectangleF(0, 0, Width, Height);
        Draw.FillRounded(e.Graphics, r, Radius, Fill);
        if (Border.A > 0) Draw.StrokeRounded(e.Graphics, r, Radius, Border, BorderWidth);
        base.OnPaint(e);
    }
}

/// <summary>A small tile that paints the accent gradient + white equalizer bars (the app logo).</summary>
internal sealed class LogoTile : Control
{
    public float[] Bars { get; set; } = { 5, 11, 7 };
    public float BarW { get; set; } = 2;
    public float Gap { get; set; } = 2;
    public float Radius { get; set; } = 7;

    public LogoTile()
    {
        DoubleBuffered = true;
        SetStyle(ControlStyles.SupportsTransparentBackColor, true);
        BackColor = Color.Transparent;
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        Draw.Hq(e.Graphics);
        var r = new RectangleF(0, 0, Width, Height);
        Draw.FillAccent(e.Graphics, r, Radius);
        Draw.LogoBars(e.Graphics, r, Bars, BarW, Gap);
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
        else Draw.FillRounded(g, track, track.Height / 2f,
            Theme.IsDark ? Theme.Surface2 : Theme.Hex("#D8D8DE"));
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
            case Kind.Solid: fg = Color.White; bg = Theme.AccentA; break;
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

/// <summary>The `.seg` segmented control: muted labels, a raised "on" pill.</summary>
internal sealed class SegmentedControl : Control
{
    public (string value, string label)[] Options { get; set; } = Array.Empty<(string, string)>();
    private string _value = "";
    public string Value
    {
        get => _value;
        set { if (_value != value) { _value = value; Invalidate(); SelectionChanged?.Invoke(this, value); } }
    }
    public event EventHandler<string>? SelectionChanged;

    public SegmentedControl()
    {
        DoubleBuffered = true;
        Font = Theme.Ui(9f);
        Height = 32;
        Cursor = Cursors.Hand;
        SetStyle(ControlStyles.SupportsTransparentBackColor, true);
        BackColor = Color.Transparent;
    }

    protected override void OnMouseClick(MouseEventArgs e)
    {
        if (Options.Length == 0) return;
        float seg = (Width - 6f) / Options.Length;
        int idx = (int)Math.Floor((e.X - 3) / seg);
        idx = Math.Max(0, Math.Min(Options.Length - 1, idx));
        Value = Options[idx].value;
        base.OnMouseClick(e);
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        var g = e.Graphics; Draw.Hq(g);
        var track = new RectangleF(0, 0, Width, Height);
        Draw.FillRounded(g, track, Theme.RadiusControl, Theme.Surface2);
        if (Options.Length == 0) return;
        float seg = (Width - 6f) / Options.Length;
        for (int i = 0; i < Options.Length; i++)
        {
            var (val, label) = Options[i];
            var cell = new RectangleF(3 + i * seg, 3, seg, Height - 6);
            bool on = val == _value;
            if (on) Draw.FillRounded(g, cell, 6, Theme.SegOn);
            TextRenderer.DrawText(g, label, Font, Rectangle.Round(cell),
                on ? Theme.Text : Theme.TextMuted,
                TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.NoPadding);
        }
    }
}

/// <summary>`.sel` dropdown: surface-2 box + chevron; opens a themed popup menu to pick.</summary>
internal sealed class VibeSelect : Control
{
    public (string value, string label)[] Options { get; set; } = Array.Empty<(string, string)>();
    private string _value = "";
    public string Value
    {
        get => _value;
        set { if (_value != value) { _value = value; Invalidate(); SelectionChanged?.Invoke(this, value); } }
    }
    public event EventHandler<string>? SelectionChanged;

    public VibeSelect()
    {
        DoubleBuffered = true;
        Font = Theme.Ui(10f);
        Size = new Size(170, 32);
        Cursor = Cursors.Hand;
        SetStyle(ControlStyles.SupportsTransparentBackColor, true);
        BackColor = Color.Transparent;
    }

    private string CurrentLabel()
    {
        foreach (var (v, l) in Options) if (v == _value) return l;
        return _value;
    }

    protected override void OnClick(EventArgs e)
    {
        var menu = new ContextMenuStrip { Renderer = new DarkMenuRenderer(), Font = Theme.Ui(10f) };
        menu.BackColor = Theme.Surface2;
        menu.ForeColor = Theme.Text;
        foreach (var (v, l) in Options)
        {
            var item = new ToolStripMenuItem(l) { ForeColor = Theme.Text, Checked = v == _value };
            string captured = v;
            item.Click += (_, _) => Value = captured;
            menu.Items.Add(item);
        }
        menu.Show(this, new Point(0, Height));
        base.OnClick(e);
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        var g = e.Graphics; Draw.Hq(g);
        var r = new RectangleF(0, 0, Width, Height);
        Draw.FillRounded(g, r, Theme.RadiusControl, Theme.Surface2);
        Draw.StrokeRounded(g, r, Theme.RadiusControl, Theme.Hairline);
        var textRect = new Rectangle(11, 0, Width - 30, Height);
        TextRenderer.DrawText(g, CurrentLabel(), Font, textRect, Theme.Text,
            TextFormatFlags.Left | TextFormatFlags.VerticalCenter | TextFormatFlags.NoPadding | TextFormatFlags.EndEllipsis);
        // chevron
        using var pen = new Pen(Theme.TextMuted, 1.6f);
        float cx = Width - 16, cy = Height / 2f - 1;
        g.DrawLines(pen, new[] { new PointF(cx - 4, cy - 2), new PointF(cx, cy + 2), new PointF(cx + 4, cy - 2) });
    }
}

/// <summary>Dark renderer for ContextMenuStrip (tray menu + VibeSelect popups).</summary>
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

/// <summary>`.bar` gradient progress bar.</summary>
internal sealed class VibeProgressBar : Control
{
    private double _fraction;
    public double Fraction
    {
        get => _fraction;
        set { _fraction = Math.Max(0, Math.Min(1, value)); Invalidate(); }
    }

    public VibeProgressBar()
    {
        DoubleBuffered = true;
        Height = 5;
        SetStyle(ControlStyles.SupportsTransparentBackColor, true);
        BackColor = Color.Transparent;
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        var g = e.Graphics; Draw.Hq(g);
        var track = new RectangleF(0, 0, Width, Height);
        Draw.FillRounded(g, track, Height / 2f, Theme.Surface2);
        float w = (float)(_fraction * Width);
        if (w > 1) Draw.FillAccent(g, new RectangleF(0, 0, w, Height), Height / 2f);
    }
}
