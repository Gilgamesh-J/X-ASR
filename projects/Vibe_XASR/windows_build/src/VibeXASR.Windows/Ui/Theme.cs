using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Runtime.InteropServices;
using System.Windows.Forms;

namespace VibeXASR.Windows.Ui;

/// <summary>
/// Windows port of the macOS <c>DesignTokens.swift</c> palette. Hex values, radii,
/// spacing and the accent gradient are copied verbatim from the macOS app so the
/// WinForms surfaces are visually faithful to the mockups. Dark is the default
/// (the macOS app is "dark-first"); the light mirror is used when Windows is in
/// light mode.
/// </summary>
public static class Theme
{
    /// <summary>When true, all scheme-aware colors resolve to their dark values.</summary>
    public static bool IsDark { get; set; } = DetectDarkMode();

    // ---- Brand accents (scheme-independent) ----
    public static readonly Color AccentA = Hex("#7C5CFF");
    public static readonly Color AccentB = Hex("#38E1D6");
    public static readonly Color Success = Hex("#45D483");
    public static readonly Color Warn    = Hex("#FFB020");
    public static readonly Color Error   = Hex("#FF5C66");

    // ---- Scheme-aware surfaces / text ----
    public static Color Bg        => IsDark ? Hex("#0E0E12") : Hex("#F6F6F8");
    public static Color Surface   => IsDark ? Hex("#1A1A22") : Hex("#FFFFFF");
    public static Color Surface2  => IsDark ? Hex("#24242E") : Hex("#EFEFF3");
    public static Color Text      => IsDark ? Hex("#ECECF1") : Hex("#1A1A22");
    public static Color TextMuted => IsDark ? Hex("#8A8A99") : Hex("#71717F");
    public static Color SegOn     => IsDark ? Hex("#3A3A46") : Hex("#FFFFFF");

    /// <summary>--hairline: white/8% (dark) · black/8% (light).</summary>
    public static Color Hairline => IsDark ? Color.FromArgb(20, 255, 255, 255)
                                           : Color.FromArgb(20, 0, 0, 0);
    /// <summary>--hairline-strong: white/14% · black/12%.</summary>
    public static Color HairlineStrong => IsDark ? Color.FromArgb(36, 255, 255, 255)
                                                 : Color.FromArgb(31, 0, 0, 0);
    /// <summary>--accent-soft: rgba(124,92,255,.16) dark / .12 light.</summary>
    public static Color AccentSoft => IsDark ? Color.FromArgb(41, 124, 92, 255)
                                             : Color.FromArgb(31, 124, 92, 255);

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

    // ---- Hex helper ----

    /// <summary>Parse <c>#RRGGBB</c> or <c>#RRGGBBAA</c> (sRGB) into a Color.</summary>
    public static Color Hex(string hex)
    {
        var s = hex.Trim();
        if (s.StartsWith('#')) s = s[1..];
        if (s.Length == 8)
        {
            int r = Convert.ToInt32(s.Substring(0, 2), 16);
            int g = Convert.ToInt32(s.Substring(2, 2), 16);
            int b = Convert.ToInt32(s.Substring(4, 2), 16);
            int a = Convert.ToInt32(s.Substring(6, 2), 16);
            return Color.FromArgb(a, r, g, b);
        }
        else
        {
            int r = Convert.ToInt32(s.Substring(0, 2), 16);
            int g = Convert.ToInt32(s.Substring(2, 2), 16);
            int b = Convert.ToInt32(s.Substring(4, 2), 16);
            return Color.FromArgb(255, r, g, b);
        }
    }

    // ---- Accent gradient ----
    // --accent: linear-gradient(100deg, #7C5CFF 0%, #38E1D6 100%). CSS 100deg flows
    // from lower-left toward upper-right; LinearGradientMode.ForwardDiagonal is the
    // closest WinForms analogue across a rect.
    public static LinearGradientBrush AccentBrush(Rectangle r)
        => new(r, AccentA, AccentB, LinearGradientMode.ForwardDiagonal);

    public static LinearGradientBrush AccentBrushHorizontal(Rectangle r)
        => new(r, AccentA, AccentB, LinearGradientMode.Horizontal);

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

    private static bool DetectDarkMode()
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
        if (!IsDark || hwnd == IntPtr.Zero) return;
        try
        {
            int on = 1;
            // 20 = DWMWA_USE_IMMERSIVE_DARK_MODE (1903+); 19 = pre-1903 fallback.
            if (DwmSetWindowAttribute(hwnd, 20, ref on, sizeof(int)) != 0)
                DwmSetWindowAttribute(hwnd, 19, ref on, sizeof(int));
        }
        catch { /* dwmapi missing — ignore */ }
    }

    /// <summary>Switch a control's (and all descendants') native scrollbars to the dark Explorer style,
    /// so AutoScroll bars render dark-on-dark instead of the light system default (the macOS-vs-Windows
    /// eyesore). Safe to call repeatedly; no-op in light mode.</summary>
    public static void ApplyDarkScrollbars(Control root)
    {
        if (!IsDark) return;
        static void Walk(Control c)
        {
            try { if (c.IsHandleCreated) SetWindowTheme(c.Handle, "DarkMode_Explorer", null); } catch { }
            foreach (Control child in c.Controls) Walk(child);
        }
        Walk(root);
    }

    [DllImport("uxtheme.dll", CharSet = CharSet.Unicode)]
    private static extern int SetWindowTheme(IntPtr hwnd, string? appName, string? idList);

    [DllImport("dwmapi.dll")]
    private static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);
}
