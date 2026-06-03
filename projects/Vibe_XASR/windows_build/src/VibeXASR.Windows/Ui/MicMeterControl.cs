using System;
using System.Drawing;
using System.Windows.Forms;

namespace VibeXASR.Windows.Ui;

/// <summary>
/// A live microphone level meter. Opens its OWN capture on a chosen device (independent of the
/// dictation engine, shared-mode) and shows a real-time bar so the user can confirm the mic is
/// picking up their voice — and which device works. The key diagnostic for "no text".
/// </summary>
internal sealed class MicMeterControl : Control
{
    private MicCapture? _cap;
    private volatile float _level;   // 0..1 smoothed display level
    private float _peak;             // decaying peak-hold marker
    private string? _deviceId;
    private readonly System.Windows.Forms.Timer _anim = new() { Interval = 40 };

    public MicMeterControl()
    {
        DoubleBuffered = true;
        Height = 18;
        SetStyle(ControlStyles.SupportsTransparentBackColor, true);
        BackColor = Color.Transparent;
        _anim.Tick += (_, _) => { _level *= 0.80f; _peak *= 0.96f; Invalidate(); };
    }

    /// <summary>Preview a device ("" / null = system default). Restarts capture if running.</summary>
    public void SetDevice(string? id)
    {
        _deviceId = string.IsNullOrEmpty(id) ? null : id;
        if (_anim.Enabled) Restart();
    }

    public void Start() { Restart(); _anim.Start(); }

    public void Stop() { _anim.Stop(); StopCap(); _level = 0; _peak = 0; Invalidate(); }

    private void Restart()
    {
        StopCap();
        try
        {
            _cap = new MicCapture(_deviceId);
            _cap.FrameAvailable += OnFrame;
            _cap.Start();
        }
        catch (Exception ex) { Diag.Log("meter mic failed: " + ex.Message); }
    }

    private void OnFrame(object? sender, float[] f)
    {
        double sum = 0;
        for (int i = 0; i < f.Length; i++) sum += f[i] * f[i];
        float rms = f.Length > 0 ? (float)Math.Sqrt(sum / f.Length) : 0;
        float disp = Math.Min(1f, rms * 12f); // scale so normal speech fills most of the bar
        if (disp > _level) _level = disp;
        if (disp > _peak) _peak = disp;
    }

    private void StopCap()
    {
        if (_cap is not null) { _cap.FrameAvailable -= OnFrame; try { _cap.Dispose(); } catch { } _cap = null; }
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        var g = e.Graphics; Draw.Hq(g);
        var track = new RectangleF(0, 0, Width, Height);
        Draw.FillRounded(g, track, Height / 2f, Theme.Surface2);

        float w = _level * Width;
        if (w > 2)
        {
            using var b = Theme.AccentBrushHorizontal(new Rectangle(0, 0, Math.Max(1, Width), Height));
            using var p = Theme.RoundedRect(new RectangleF(0, 0, w, Height), Height / 2f);
            g.FillPath(b, p);
        }
        // peak-hold tick
        float px = _peak * Width;
        if (px > 3)
            using (var pen = new Pen(Theme.AccentB, 2f))
                g.DrawLine(pen, px, 2, px, Height - 2);
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing) { _anim.Dispose(); StopCap(); }
        base.Dispose(disposing);
    }
}
