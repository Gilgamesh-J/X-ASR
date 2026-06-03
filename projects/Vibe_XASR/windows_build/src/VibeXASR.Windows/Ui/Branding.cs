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

    [System.Runtime.InteropServices.DllImport("user32.dll", SetLastError = true)]
    private static extern bool DestroyIcon(IntPtr handle);
}
