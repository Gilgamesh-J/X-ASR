using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Runtime.InteropServices;
using System.Windows.Forms;

namespace VibeXASR.Windows.Ui;

/// <summary>
/// WinForms view of <see cref="DesignTokens"/>. Every colour property here is a lookup into the one
/// shared table — this class holds no hex values of its own any more. WPF reads the same table
/// through `Ui/Wpf/Palette.cs`, so the two stacks cannot drift.
///
/// Scheme selection is <see cref="IsDark"/>, which the tray app sets from the user's theme
/// preference ("auto" follows Windows) via <see cref="ResolveDark"/>.
/// </summary>
public static class Theme
{
    /// <summary>When true, every scheme-aware colour resolves to its dark value.</summary>
    public static bool IsDark { get; set; } = DetectDarkMode();

    /// <summary>Turn a stored preference into the effective scheme.
    /// <c>"auto"</c> (or anything unrecognised) follows Windows; <c>"dark"</c>/<c>"light"</c> pin it.</summary>
    public static bool ResolveDark(string? preference) => preference?.Trim().ToLowerInvariant() switch
    {
        "dark" => true,
        "light" => false,
        _ => DetectDarkMode(),
    };

    /// <summary>
    /// Resolve a preference and push the result into BOTH UI stacks. Returns false when nothing
    /// changed (so callers can skip the expensive repaint).
    ///
    /// This is the single place a scheme switch happens: the tray app calls it at startup, on the
    /// Windows theme broadcast, and when the user picks 外观; the dev screenshot host calls it with
    /// the preference it was handed. Keeping one implementation means a fix here cannot miss a
    /// caller — and it makes the screenshot host a real test of the shipping path rather than a
    /// lookalike.
    ///
    /// WPF windows re-resolve their <c>DynamicResource</c> lookups by themselves; WinForms surfaces
    /// copy colours onto controls, so the caller still has to re-apply those (hence the callback).
    /// </summary>
    public static bool ApplyPreference(string? preference, Action<bool>? onWinFormsSurface = null)
    {
        bool dark = ResolveDark(preference);
        if (dark == IsDark && dark == Wpf.Palette.Dark) return false;
        IsDark = dark;
        Wpf.Palette.Apply(dark);
        onWinFormsSurface?.Invoke(dark);
        return true;
    }

    /// <summary>Resolved token → WinForms colour.</summary>
    private static Color C(string key)
    {
        var c = DesignTokens.Color(key, IsDark);
        return Color.FromArgb(c.A, c.R, c.G, c.B);
    }

    // ---- Brand accents (decorative) ----
    // Logos, the waveform and gradients only. They are NOT text: #7C5CFF on a dark panel is 3.98:1
    // and on white 4.35:1, both below the 4.5:1 AA floor. Use AccentText when the accent is the glyph.
    public static Color AccentA => C("AccentA");
    public static Color AccentB => C("AccentB");
    public static Color Success => C("Success");
    public static Color Warn    => C("Warn");
    /// <summary>Danger used as text (the token is named Danger everywhere; Error is the old name).</summary>
    public static Color Error   => C("Danger");
    public static Color Danger  => C("Danger");

    // ---- Accent as text / as a white-text fill ----
    /// <summary>Accent used AS TEXT (links, selected labels). 5.53:1 dark · 6.22:1 light.</summary>
    public static Color AccentText => C("AccentText");
    /// <summary>Accent used AS a filled button under white text. White on it: 5.40:1 dark · 6.22:1 light.</summary>
    public static Color AccentFill => C("AccentFill");
    /// <summary>Green fill carrying white text (5.41:1) — text-success green is too bright for that role.</summary>
    public static Color SuccessFill => C("SuccessFill");
    /// <summary>Red fill carrying white text: 5.01:1 dark · 6.44:1 light.</summary>
    public static Color DangerFill => C("DangerFill");

    // ---- Scheme-aware surfaces / text ----
    public static Color Bg        => C("Bg");
    public static Color Surface   => C("Surface");
    public static Color Surface2  => C("Surface2");
    public static Color Text      => C("Text");
    public static Color TextMuted => C("TextMuted");
    /// <summary>Tertiary text (timestamps, hints). 5.02:1 dark · 5.27:1 light.</summary>
    public static Color TextFaint => C("TextFaint");
    public static Color SegOn     => C("SegOn");

    /// <summary>--hairline: white/10% (dark) · black/8% (light).</summary>
    public static Color Hairline => C("Hairline");
    /// <summary>--hairline-strong: white/20% · black/14%.</summary>
    public static Color HairlineStrong => C("HairlineStrong");
    /// <summary>--accent-soft: rgba(124,92,255,.20) dark / .12 light.</summary>
    public static Color AccentSoft => C("AccentSoft");

    /// <summary>Switch track when OFF (the same audited value the WPF Toggle uses — the WinForms one
    /// used to guess at it with a literal that only existed for the dark scheme).</summary>
    public static Color ToggleTrack => C("ToggleTrack");

    // ---- Radii (px) ----
    public const int RadiusPanel   = 16;
    public const int RadiusCard    = 12;
    public const int RadiusControl = 8;

    // ---- Spacing scale (px) ----
    public const int S1 = 4, S2 = 8, S3 = 12, S4 = 16, S6 = 24, S8 = 32;

    // ---- Fonts ----
    // macOS uses SF Pro (UI) + JetBrains Mono / SF Mono. The Windows analogues are
    // Segoe UI (the system UI face) and Cascadia Mono / Consolas.
    public const string UiFamily = "Segoe UI";
    public static readonly string MonoFamily = ResolveMono();

    public static Font Ui(float size, FontStyle style = FontStyle.Regular)
        => new(UiFamily, size, style, GraphicsUnit.Point);

    public static Font Mono(float size, FontStyle style = FontStyle.Regular)
        => new(MonoFamily, size, style, GraphicsUnit.Point);

    // ---- Accent gradient ----
    // --accent: linear-gradient(100deg, #7C5CFF 0%, #38E1D6 100%). CSS 100deg flows
    // from lower-left toward upper-right; LinearGradientMode.ForwardDiagonal is the
    // closest WinForms analogue across a rect.
    public static LinearGradientBrush AccentBrush(Rectangle r)
        => new(r, AccentA, AccentB, LinearGradientMode.ForwardDiagonal);

    private static Color ToColor(Rgba c) => Color.FromArgb(c.A, c.R, c.G, c.B);

    // ---- Rounded-rect path helper ----

    /// <summary>A rounded-rectangle path (used everywhere for cards / pills / panels).</summary>
    public static GraphicsPath RoundedRect(RectangleF r, float radius)
    {
        var path = new GraphicsPath();
        float d = radius * 2f;
        if (d <= 0f) { path.AddRectangle(r); path.CloseFigure(); return path; }
        d = Math.Min(d, Math.Min(r.Width, r.Height));
        path.AddArc(r.X, r.Y, d, d, 180, 90);
        path.AddArc(r.Right - d, r.Y, d, d, 270, 90);
        path.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
        path.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
        path.CloseFigure();
        return path;
    }

    // ---- Theme detection ----

    /// <summary>What Windows says: AppsUseLightTheme == 0 means dark apps.</summary>
    public static bool DetectDarkMode()
    {
        try
        {
            using var key = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(
                @"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize");
            // AppsUseLightTheme == 0 => dark apps.
            if (key?.GetValue("AppsUseLightTheme") is int v) return v == 0;
        }
        catch { /* registry unavailable — fall through */ }
        return true; // dark-first like macOS
    }

    private static string ResolveMono()
    {
        foreach (var name in new[] { "Cascadia Mono", "Cascadia Code", "Consolas", "Lucida Console" })
        {
            try
            {
                using var f = new Font(name, 10f);
                if (string.Equals(f.Name, name, StringComparison.OrdinalIgnoreCase)) return name;
            }
            catch { /* try next */ }
        }
        return "Consolas";
    }

    // ---- Dark title bar (DWM) ----

    /// <summary>
    /// Ask DWM to paint the window's title bar dark (Win10 20H1+/Win11). No-op on
    /// older builds. Call after the handle is created.
    /// </summary>
    public static void ApplyDarkTitleBar(IntPtr hwnd)
    {
        // Deliberately does NOT bail out in light mode: it must write 0 again, otherwise a window
        // flipped from dark to light keeps its dark title bar (the attribute is sticky).
        if (hwnd == IntPtr.Zero) return;
        try
        {
            int on = IsDark ? 1 : 0;
            // 20 = DWMWA_USE_IMMERSIVE_DARK_MODE (1903+); 19 = pre-1903 fallback.
            if (DwmSetWindowAttribute(hwnd, 20, ref on, sizeof(int)) != 0)
                DwmSetWindowAttribute(hwnd, 19, ref on, sizeof(int));
        }
        catch { /* dwmapi missing — ignore */ }
    }

    /// <summary>Switch a control's (and all descendants') native scrollbars to the dark Explorer style,
    /// so AutoScroll bars render dark-on-dark instead of the light system default (the macOS-vs-Windows
    /// eyesore). Safe to call repeatedly; in light mode it writes the light style back.</summary>
    public static void ApplyDarkScrollbars(Control root)
    {
        // Same as the title bar: writing "Explorer" back is what undoes "DarkMode_Explorer" on a
        // live switch to light. Returning early here left dark scrollbars on the light theme.
        string theme = IsDark ? "DarkMode_Explorer" : "Explorer";
        static void Walk(Control c, string name)
        {
            try { if (c.IsHandleCreated) SetWindowTheme(c.Handle, name, null); } catch { }
            foreach (Control child in c.Controls) Walk(child, name);
        }
        Walk(root, theme);
    }

    [DllImport("uxtheme.dll", CharSet = CharSet.Unicode)]
    private static extern int SetWindowTheme(IntPtr hwnd, string? appName, string? idList);

    [DllImport("dwmapi.dll")]
    private static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);
}
