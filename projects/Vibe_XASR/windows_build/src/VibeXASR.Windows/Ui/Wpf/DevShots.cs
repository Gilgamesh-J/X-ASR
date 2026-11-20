using System;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;

namespace VibeXASR.Windows.Ui.Wpf;

/// <summary>Dev-only self-capture for the VIBEXASR_OPEN preview hooks (never touched by normal runs).
///
/// VIBEXASR_SHOT=&lt;png&gt;                 capture once and close
/// VIBEXASR_SHOT_SEQ=&lt;n&gt; (n &gt; 1)        capture n frames, 30 ms apart, as &lt;name&gt;_0.png … _n-1.png
///
/// The sequence mode exists because a single screenshot cannot prove an animation ran: it only shows
/// the settled state. Frames taken 30 ms apart land on the entrance curve and show it mid-flight.
/// <see cref="RenderTargetBitmap"/> reads animated properties from the running clock, so the frames
/// are the real thing, not a re-render of the end state.</summary>
internal static class DevShots
{
    public static string? Target => Environment.GetEnvironmentVariable("VIBEXASR_SHOT");

    /// <summary>How many frames to take (1 = just the plain VIBEXASR_SHOT path).</summary>
    public static int Seq
        => int.TryParse(Environment.GetEnvironmentVariable("VIBEXASR_SHOT_SEQ"), out int n) && n > 1 ? n : 1;

    /// <summary>Render the window to a PNG. Returns the path written, or null on any failure.</summary>
    public static string? Save(Window w, string path)
    {
        try
        {
            w.UpdateLayout();
            // Render the window's CONTENT root, sized to the content's own layout size.
            // Before this, the bitmap was sized to Window.ActualWidth/ActualHeight — which is the OUTER
            // box, title bar included — while RenderTargetBitmap.Render(w) only paints the client area.
            // Every capture therefore carried a transparent strip at the bottom (38 px at 1000x720),
            // which viewers show as a black band.
            // Size to the CLIENT area (the content root's layout size) but render the WINDOW visual:
            // Window.Background is painted by the window itself, not by the content root, so rendering
            // the root alone leaves the unpainted side of the layout transparent.
            var root = w.Content as FrameworkElement ?? w;
            // Floor, not ceiling: the layout size is fractional at 125% DPI, and rounding up leaves the
            // last row/column outside the rendered visual (a 1 px transparent edge in every PNG).
            int width = (int)Math.Floor(root.ActualWidth);
            int height = (int)Math.Floor(root.ActualHeight);
            if (width <= 0 || height <= 0) return null;
            var rtb = new RenderTargetBitmap(width, height, 96, 96, PixelFormats.Pbgra32);
            rtb.Render(w);
            var enc = new PngBitmapEncoder();
            enc.Frames.Add(BitmapFrame.Create(rtb));
            using var fs = System.IO.File.Create(path);
            enc.Save(fs);
            return path;
        }
        catch { return null; }
    }

    /// <summary>Wait <paramref name="settleMs"/>, then capture <see cref="Seq"/> frames
    /// <paramref name="intervalMs"/> apart, then call <paramref name="finish"/> (usually host.Close()).</summary>
    public static void Capture(Window w, int settleMs, int intervalMs, Action finish)
    {
        var shot = Target;
        if (string.IsNullOrEmpty(shot)) { finish(); return; }
        int frames = Seq;
        int i = 0;
        var timer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(Math.Max(1, settleMs)) };
        timer.Tick += (_, _) =>
        {
            string path = shot;
            if (frames > 1)
            {
                string dir = System.IO.Path.GetDirectoryName(shot) ?? ".";
                path = System.IO.Path.Combine(dir,
                    System.IO.Path.GetFileNameWithoutExtension(shot) + "_" + i + System.IO.Path.GetExtension(shot));
            }
            Save(w, path);
            i++;
            if (i >= frames) { timer.Stop(); finish(); return; }
            timer.Interval = TimeSpan.FromMilliseconds(Math.Max(1, intervalMs));
        };
        timer.Start();
    }
}
