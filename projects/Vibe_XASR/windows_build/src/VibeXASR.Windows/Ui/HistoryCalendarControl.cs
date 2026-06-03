using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Windows.Forms;
using VibeXASR.Windows.Storage;

namespace VibeXASR.Windows.Ui;

/// <summary>
/// Month heatmap calendar (the v1.4.0 日历视图). Draws a ‹ month 今天 › header, a weekday row, a
/// 6×7 grid of day cells shaded by per-day record count (heat level 0–4), and a少…多 legend.
/// Clicking a day with records fires <see cref="DaySelected"/> with its day-key (or null to clear).
/// Faithful port of macOS HistoryCalendar's MonthHeatmap.
/// </summary>
internal sealed class HistoryCalendarControl : Control
{
    private DateTime _cursor = DateTime.Today;
    private Dictionary<string, int> _counts = new();
    private string? _selected;
    private string _todayKey = HistoryClustering.DayKey(DateTimeOffset.Now);

    private List<DateTime> _grid = HistoryClustering.MonthGrid(DateTime.Today);
    private readonly RectangleF[] _cells = new RectangleF[42];
    private RectangleF _prev, _today, _next;

    private static readonly string[] Weekdays = { "一", "二", "三", "四", "五", "六", "日" };

    public event Action<string?>? DaySelected;
    public event Action? MonthChanged;

    public DateTime MonthCursor => _cursor;
    public string? Selected { get => _selected; set { _selected = value; Invalidate(); } }

    public HistoryCalendarControl()
    {
        DoubleBuffered = true;
        BackColor = Theme.Surface;
        Cursor = Cursors.Default;
    }

    public void SetData(DateTime cursor, Dictionary<string, int> counts, string? selected)
    {
        _cursor = new DateTime(cursor.Year, cursor.Month, 1);
        _counts = counts ?? new();
        _selected = selected;
        _todayKey = HistoryClustering.DayKey(DateTimeOffset.Now);
        _grid = HistoryClustering.MonthGrid(_cursor);
        RelayoutAndResize();
        Invalidate();
    }

    protected override void OnSizeChanged(EventArgs e) { base.OnSizeChanged(e); RelayoutAndResize(); Invalidate(); }

    private const int HeaderH = 32, WeekH = 20, Gap = 5, Pad = 2;

    private float _cellH;
    private void RelayoutAndResize()
    {
        int w = Width;
        if (w <= 0) return;
        _prev = new RectangleF(Pad, 2, 26, 26);
        _next = new RectangleF(w - Pad - 26, 2, 26, 26);
        _today = new RectangleF(w - Pad - 26 - 8 - 46, 4, 46, 22);
        float cellW = (w - Pad * 2 - Gap * 6) / 7f;
        _cellH = cellW / 1.15f;
        float gy = HeaderH + WeekH;
        for (int i = 0; i < 42; i++)
        {
            int r = i / 7, c = i % 7;
            _cells[i] = new RectangleF(Pad + c * (cellW + Gap), gy + r * (_cellH + Gap), cellW, _cellH);
        }
        int legendTop = (int)(gy + 6 * (_cellH + Gap)) + 8;
        Height = legendTop + 22;
    }

    private static Color Bg(int lvl) => lvl switch
    {
        1 => Color.FromArgb(41, Theme.AccentA),
        2 => Color.FromArgb(82, Theme.AccentA),
        3 => Color.FromArgb(140, Theme.AccentA),
        4 => Color.FromArgb(217, Theme.AccentA),
        _ => Theme.Surface2,
    };
    private static Color Fg(int lvl) => lvl switch
    {
        0 => Color.FromArgb(120, Theme.TextMuted),
        1 => Theme.TextMuted,
        2 => Theme.Text,
        _ => Color.White,
    };

    protected override void OnPaint(PaintEventArgs e)
    {
        var g = e.Graphics; g.SmoothingMode = SmoothingMode.AntiAlias; g.TextRenderingHint = System.Drawing.Text.TextRenderingHint.ClearTypeGridFit;
        int w = Width;

        // header: ‹  yyyy年M月  [今天]  ›
        DrawNav(g, _prev, "‹");
        DrawNav(g, _next, "›");
        using (var tb = new SolidBrush(Theme.Surface2))
        using (var p = Theme.RoundedRect(_today, 6)) g.FillPath(tb, p);
        TextRenderer.DrawText(g, "今天", Theme.Ui(9f), Rectangle.Round(_today), Theme.TextMuted,
            TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.NoPadding);
        TextRenderer.DrawText(g, $"{_cursor.Year}年{_cursor.Month}月", Theme.Ui(11f, FontStyle.Bold),
            new Rectangle(30, 0, w - 160, HeaderH), Theme.Text,
            TextFormatFlags.Left | TextFormatFlags.VerticalCenter | TextFormatFlags.NoPadding);

        // weekday row
        float cellW = (w - Pad * 2 - Gap * 6) / 7f;
        for (int c = 0; c < 7; c++)
            TextRenderer.DrawText(g, Weekdays[c], Theme.Ui(8.5f),
                new Rectangle((int)(Pad + c * (cellW + Gap)), HeaderH, (int)cellW, WeekH), Theme.TextMuted,
                TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.NoPadding);

        // cells
        int maxN = 1;
        foreach (var v in _counts.Values) if (v > maxN) maxN = v;
        for (int i = 0; i < 42 && i < _grid.Count; i++)
        {
            var d = _grid[i];
            var k = HistoryClustering.DayKey(new DateTimeOffset(d, DateTimeOffset.Now.Offset));
            int n = _counts.TryGetValue(k, out var cnt) ? cnt : 0;
            bool outMonth = d.Month != _cursor.Month;
            int lvl = HistoryClustering.HeatLevel(n, maxN);
            var rect = _cells[i];

            using (var b = new SolidBrush(outMonth ? Color.FromArgb(64, Bg(lvl)) : Bg(lvl)))
            using (var p = Theme.RoundedRect(rect, 8)) g.FillPath(b, p);

            Color border = k == _todayKey ? Theme.AccentA : k == _selected ? Theme.Text : Theme.Hairline;
            float bw = (k == _todayKey || k == _selected) ? 2f : 1f;
            using (var pen = new Pen(outMonth ? Color.FromArgb(64, border) : border, bw))
            using (var p = Theme.RoundedRect(rect, 8)) g.DrawPath(pen, p);

            var fg = outMonth ? Color.FromArgb(64, Fg(lvl)) : Fg(lvl);
            TextRenderer.DrawText(g, d.Day.ToString(), Theme.Mono(9.5f, FontStyle.Bold),
                new Rectangle((int)rect.X + 6, (int)rect.Y + 4, (int)rect.Width - 8, 16), fg,
                TextFormatFlags.Left | TextFormatFlags.Top | TextFormatFlags.NoPadding);
            if (n > 0)
                TextRenderer.DrawText(g, n.ToString(), Theme.Mono(8.5f, FontStyle.Bold),
                    new Rectangle((int)rect.X, (int)rect.Bottom - 18, (int)rect.Width - 6, 16), fg,
                    TextFormatFlags.Right | TextFormatFlags.Bottom | TextFormatFlags.NoPadding);
        }

        // legend: 少 ▢▢▢▢▢ 多
        int ly = (int)(HeaderH + WeekH + 6 * (_cellH + Gap)) + 10;
        int lx = w - Pad - (14 * 5 + 4 * 5 + 40);
        TextRenderer.DrawText(g, "少", Theme.Ui(8.5f), new Rectangle(lx, ly - 2, 18, 16), Theme.TextMuted, TextFormatFlags.NoPadding);
        lx += 18;
        for (int l = 0; l < 5; l++)
        {
            using var b = new SolidBrush(Bg(l));
            using var p = Theme.RoundedRect(new RectangleF(lx, ly, 14, 14), 4);
            g.FillPath(b, p); lx += 18;
        }
        TextRenderer.DrawText(g, "多", Theme.Ui(8.5f), new Rectangle(lx, ly - 2, 18, 16), Theme.TextMuted, TextFormatFlags.NoPadding);
    }

    private void DrawNav(Graphics g, RectangleF r, string glyph)
    {
        TextRenderer.DrawText(g, glyph, Theme.Ui(13f), Rectangle.Round(r), Theme.TextMuted,
            TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.NoPadding);
    }

    protected override void OnMouseClick(MouseEventArgs e)
    {
        base.OnMouseClick(e);
        var pt = e.Location;
        if (_prev.Contains(pt)) { _cursor = _cursor.AddMonths(-1); _grid = HistoryClustering.MonthGrid(_cursor); RelayoutAndResize(); MonthChanged?.Invoke(); Invalidate(); return; }
        if (_next.Contains(pt)) { _cursor = _cursor.AddMonths(1); _grid = HistoryClustering.MonthGrid(_cursor); RelayoutAndResize(); MonthChanged?.Invoke(); Invalidate(); return; }
        if (_today.Contains(pt)) { _cursor = new DateTime(DateTime.Today.Year, DateTime.Today.Month, 1); _grid = HistoryClustering.MonthGrid(_cursor); RelayoutAndResize(); MonthChanged?.Invoke(); Invalidate(); return; }
        for (int i = 0; i < 42 && i < _grid.Count; i++)
        {
            if (!_cells[i].Contains(pt)) continue;
            var d = _grid[i];
            if (d.Month != _cursor.Month) return;
            var k = HistoryClustering.DayKey(new DateTimeOffset(d, DateTimeOffset.Now.Offset));
            int n = _counts.TryGetValue(k, out var cnt) ? cnt : 0;
            // toggle: re-click the selected day clears the filter
            DaySelected?.Invoke(n > 0 ? (k == _selected ? null : k) : null);
            return;
        }
    }

    protected override void OnMouseMove(MouseEventArgs e)
    {
        base.OnMouseMove(e);
        bool overHit = _prev.Contains(e.Location) || _next.Contains(e.Location) || _today.Contains(e.Location);
        if (!overHit)
            for (int i = 0; i < 42 && i < _grid.Count; i++)
                if (_cells[i].Contains(e.Location) && _grid[i].Month == _cursor.Month)
                { var k = HistoryClustering.DayKey(new DateTimeOffset(_grid[i], DateTimeOffset.Now.Offset)); if (_counts.ContainsKey(k)) { overHit = true; break; } }
        Cursor = overHit ? Cursors.Hand : Cursors.Default;
    }
}
