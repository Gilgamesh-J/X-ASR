using System;
using System.Drawing;
using System.Windows.Forms;

namespace VibeXASR.Windows.Ui;

/// <summary>
/// A small top-most progress dialog shown on first launch (or when switching to an
/// un-downloaded tier) while the model files stream from HuggingFace. Borderless,
/// centered, dark — matches the app chrome.
/// </summary>
public sealed class DownloadForm : Form
{
    private readonly LogoTile _logo;
    private readonly Label _title;
    private readonly Label _detail;
    private readonly VibeProgressBar _bar;

    public DownloadForm()
    {
        FormBorderStyle = FormBorderStyle.None;
        ShowInTaskbar = false;
        TopMost = true;
        StartPosition = FormStartPosition.CenterScreen;
        DoubleBuffered = true;
        BackColor = Theme.Surface;
        ClientSize = new Size(380, 150);
        Font = Theme.Ui(9.5f);

        _logo = new LogoTile { Bars = new float[] { 8, 18, 24, 14, 9 }, BarW = 3, Gap = 2, Radius = 12,
                               Bounds = new Rectangle(24, 24, 44, 44) };
        _title = new Label { Text = L10n.T("dl.title"), Font = Theme.Ui(12f, FontStyle.Bold), ForeColor = Theme.Text,
                             AutoSize = true, Location = new Point(82, 30), BackColor = Color.Transparent };
        _detail = new Label { Text = "", Font = Theme.Mono(8.5f), ForeColor = Theme.TextMuted,
                              AutoSize = false, Location = new Point(82, 54), Size = new Size(270, 16),
                              BackColor = Color.Transparent };
        _bar = new VibeProgressBar { Location = new Point(24, 104), Size = new Size(332, 6) };
        Controls.AddRange(new Control[] { _logo, _title, _detail, _bar });
    }

    protected override void OnHandleCreated(EventArgs e)
    {
        base.OnHandleCreated(e);
        Region = new Region(Theme.RoundedRect(new RectangleF(0, 0, Width, Height), 16));
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        base.OnPaint(e);
        Draw.StrokeRounded(e.Graphics, new RectangleF(0, 0, Width, Height), 16, Theme.Hairline);
    }

    /// <summary>Update progress (0..1) + a detail line. Safe to call from any thread.</summary>
    public void Report(double fraction, string detail)
    {
        if (IsDisposed) return;
        if (InvokeRequired) { try { BeginInvoke(() => Report(fraction, detail)); } catch { } return; }
        _bar.Fraction = fraction;
        _detail.Text = detail;
    }
}
