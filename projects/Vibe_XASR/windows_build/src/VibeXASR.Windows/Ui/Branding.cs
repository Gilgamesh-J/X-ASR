using System;
using System.Drawing;
using System.Drawing.Drawing2D;

namespace VibeXASR.Windows.Ui;

/// <summary>
/// Generates the app/tray icon at runtime (no .ico asset to ship): the accent-gradient
/// rounded tile with the white equalizer bars — the same mark used across the UI.
/// </summary>
public static class Branding
{
    private static Icon? _cached;

    /// <summary>The shared app icon (cached). Used for the tray and every window. Prefers the
    /// exe's embedded multi-res icon (so tray/windows match Explorer); falls back to drawing it.</summary>
    public static Icon AppIcon => _cached ??= Load();

    private static Icon Load()
    {
        try
        {
            var exe = Environment.ProcessPath;
            if (!string.IsNullOrEmpty(exe))
            {
                var ico = Icon.ExtractAssociatedIcon(exe);
                if (ico is not null) return ico;
            }
        }
        catch { /* fall back to the drawn icon */ }
        return Build(32);
    }

    private static Icon Build(int size)
    {
        using var bmp = new Bitmap(size, size);
        using (var g = Graphics.FromImage(bmp))
        {
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.Clear(Color.Transparent);
            var r = new RectangleF(1, 1, size - 2, size - 2);
            using (var path = Theme.RoundedRect(r, size * 0.28f))
            using (var brush = new LinearGradientBrush(Rectangle.Round(r), Theme.AccentA, Theme.AccentB,
                       LinearGradientMode.ForwardDiagonal))
                g.FillPath(brush, path);

            float[] hs = { size * 0.30f, size * 0.55f, size * 0.40f };
            float barW = size * 0.10f, gap = size * 0.09f;
            Draw.LogoBars(g, r, hs, barW, gap);
        }
        // GetHicon -> Icon; clone so we can free the GDI handle immediately.
        IntPtr h = bmp.GetHicon();
        try { using var tmp = Icon.FromHandle(h); return (Icon)tmp.Clone(); }
        finally { DestroyIcon(h); }
    }

    /// <summary>Tray status (mirrors macOS's tinted menu-bar bars). Drives <see cref="StateIcon"/>.</summary>
    public enum TrayState { Ready, Recording, OnCall, Error }

    private static readonly Icon?[] _stateCache = new Icon?[4];

    /// <summary>The tray icon for a state: the brand tile + a colored status dot
    /// (red = recording, green = OnCall, orange = error; none when ready). Cached per state.</summary>
    public static Icon StateIcon(TrayState state) => _stateCache[(int)state] ??= BuildState(32, state);

    private static Icon BuildState(int size, TrayState state)
    {
        using var bmp = new Bitmap(size, size);
        using (var g = Graphics.FromImage(bmp))
        {
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.Clear(Color.Transparent);
            var r = new RectangleF(1, 1, size - 2, size - 2);
            using (var path = Theme.RoundedRect(r, size * 0.28f))
            using (var brush = new LinearGradientBrush(Rectangle.Round(r), Theme.AccentA, Theme.AccentB,
                       LinearGradientMode.ForwardDiagonal))
                g.FillPath(brush, path);
            float[] hs = { size * 0.30f, size * 0.55f, size * 0.40f };
            float barW = size * 0.10f, gap = size * 0.09f;
            Draw.LogoBars(g, r, hs, barW, gap);

            Color? dot = state switch
            {
                TrayState.Recording => Color.FromArgb(255, 59, 48),   // red
                TrayState.OnCall    => Color.FromArgb(48, 209, 88),   // green
                TrayState.Error     => Color.FromArgb(255, 149, 0),   // orange
                _ => (Color?)null,
            };
            if (dot is { } dc)
            {
                float d = size * 0.46f, dx = size - d - 0.5f, dy = size - d - 0.5f;
                using (var halo = new SolidBrush(Color.White))
                    g.FillEllipse(halo, dx - 1.6f, dy - 1.6f, d + 3.2f, d + 3.2f);   // white ring for contrast
                using var db = new SolidBrush(dc);
                g.FillEllipse(db, dx, dy, d, d);
            }
        }
        IntPtr h = bmp.GetHicon();
        try { using var tmp = Icon.FromHandle(h); return (Icon)tmp.Clone(); }
        finally { DestroyIcon(h); }
    }

    [System.Runtime.InteropServices.DllImport("user32.dll", SetLastError = true)]
    private static extern bool DestroyIcon(IntPtr handle);
}
