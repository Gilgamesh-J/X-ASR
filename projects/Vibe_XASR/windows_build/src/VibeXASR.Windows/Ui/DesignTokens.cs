using System;
using System.Collections.Generic;

namespace VibeXASR.Windows.Ui;

/// <summary>One colour, straight sRGB. Both UI stacks build their own colour type from it.</summary>
public readonly record struct Rgba(byte A, byte R, byte G, byte B);

/// <summary>
/// THE colour table. Every scheme-aware value in the app is declared here once, as a
/// dark/light pair, and both UI stacks are thin readers of it:
///
///   * WPF (`Ui/Wpf/Palette.cs`) turns the whole table into one ResourceDictionary of frozen
///     brushes, which XAML consumes with `{DynamicResource Key}`.
///   * WinForms (`Ui/Theme.cs`) exposes the same names as `System.Drawing.Color` properties.
///
/// Before this file the two stacks were separate copies of the same hex list (plus five more in
/// the individual windows), so a token change meant editing six places and any miss showed up as
/// two slightly different greys in the same window.
///
/// Value format: <c>#RRGGBB</c>, or <c>#AARRGGBB</c> when the token carries alpha (the hairline /
/// hover / track washes). The alpha lives in the value on purpose: "white at 8%" and "black at 8%"
/// are the same token seen in the two schemes, and splitting them across two tables is how the
/// light theme lost every hairline it had.
///
/// Naming rules that came out of the contrast audit:
///   * <c>AccentA</c>/<c>AccentB</c> are BRAND marks — gradients, logos, waveforms. Decorative only,
///     never text: #7C5CFF is 4.18:1 on the dark panel (3.98:1 on the sidebar) and 4.35:1 on white.
///   * <c>AccentText</c> is the accent used AS TEXT and is tuned to clear 4.5:1 on every surface.
///   * <c>*Fill</c> tokens are backgrounds carrying WHITE text, so each is verified against white
///     at >= 4.5:1 — a filled button is text contrast turned inside out.
/// </summary>
public static class DesignTokens
{
    // ------------------------------------------------------------------ colours

    private static readonly Dictionary<string, (string Dark, string Light)> Colors = new(StringComparer.Ordinal)
    {
        // ---- surfaces ----
        ["Bg"]         = ("#0E0E12", "#F6F6F8"),
        ["Surface"]    = ("#15151B", "#FFFFFF"),
        ["Surface2"]   = ("#1E1E26", "#EFEFF3"),
        ["Field"]      = ("#16161C", "#F2F2F6"),
        ["SegOn"]      = ("#3A3A46", "#FFFFFF"),
        // Translucent washes are "white at N%" in dark and "black at N%" in light — 8% of white
        // over #FFFFFF is invisible, which is exactly how the light theme lost its separators.
        ["Hairline"]       = ("#1AFFFFFF", "#141A1A22"),
        ["HairlineStrong"] = ("#33FFFFFF", "#241A1A22"),
        ["Hover"]          = ("#14FFFFFF", "#0D1A1A22"),
        ["InnerStroke"]    = ("#0FFFFFFF", "#0A1A1A22"),

        // ---- text ----
        ["Text"]      = ("#ECECF1", "#1A1A22"),   // 15.44:1 dark · 17.29:1 light
        ["TextMuted"] = ("#9A9AAB", "#63636F"),   // 6.57:1 dark · 5.92:1 light
        ["TextFaint"] = ("#858597", "#6B6B75"),   // 5.02:1 dark · 5.27:1 light

        // ---- brand (decorative) ----
        ["AccentA"] = ("#7C5CFF", "#7C5CFF"),
        ["AccentB"] = ("#38E1D6", "#0A756F"),

        // ---- accent as text / as a white-text fill (contrast-verified) ----
        ["AccentText"] = ("#9478FF", "#6242E0"),   // 5.53 / 6.22 on a panel (5.04 / 5.43 on a card)
        ["AccentFill"] = ("#6D4AF0", "#6242E0"),   // white on it: 5.40 / 6.22
        ["AccentSoft"] = ("#337C5CFF", "#1F7C5CFF"),

        // ---- status ----
        ["Success"]     = ("#45D483", "#0A713E"),   // as text: 9.52 / 5.32 on a panel, 4.56 on its own banner tint
        ["SuccessFill"] = ("#0B7A45", "#0B7A45"),   // white on it: 5.41
        ["Warn"]        = ("#FFB020", "#8A5600"),   // as text: 9.94 / 6.16
        ["Danger"]      = ("#FF5C66", "#C4262F"),   // as text: 6.04 / 5.73
        ["DangerFill"]  = ("#D62828", "#B4262F"),   // white on it: 5.01 / 6.44
        ["Danger25"] = ("#29FF6B6B", "#29D62828"),

        // ---- controls ----
        // Off-track: the pill is a COMPONENT, so WCAG 1.4.11 wants 3:1 against the card behind it —
        // not just against its own knob (0x2E of white was 9.2:1 vs the knob but only 1.80:1 vs the
        // #1E1E26 card, i.e. the off switch sank into the card exactly like the white-on-white light
        // bug did). 0x5C composites to #6F6F74 = 3.31:1 on the card.
        // The same wash over a white card is invisible, so light uses 0x80 of #1A1A22 -> #84848A =
        // 3.24:1 on its card (measured from a rendered frame, not from the alpha).
        ["ToggleTrack"] = ("#5CFFFFFF", "#801A1A22"),
        // White knob in both schemes: it separates from the track by its own drop shadow, and a dark
        // knob in the light scheme reads as an "off" dot inside an already-off pill.
        ["ToggleThumb"] = ("#FFFFFF", "#FFFFFF"),
        ["ScrollThumb"] = ("#4DFFFFFF", "#451A1A22"),
        ["CloseBtnBg"]  = ("#E5202028", "#F0FFFFFF"),
    };

    // name -> (darkFrom, darkTo, lightFrom, lightTo, vertical)
    private static readonly Dictionary<string, (string D0, string D1, string L0, string L1, bool Vertical)> Gradients =
        new(StringComparer.Ordinal)
    {
        // --accent: linear-gradient(100deg, #7C5CFF 0%, #38E1D6 100%)
        ["AccentGrad"]     = ("#7C5CFF", "#38E1D6", "#7C5CFF", "#28C9BE", false),
        ["AccentFillGrad"] = ("#6D4AF0", "#5B3FD6", "#6242E0", "#4B30B8", false),   // worst stop 5.40 / 6.22
        ["Sidebar"]        = ("#1A1A22", "#141419", "#FFFFFF", "#F2F2F6", true),
    };

    // name -> ((color, opacity, blur, depth) dark, (…) light)
    private static readonly Dictionary<string, ((string C, double O, double B, double D) Dark, (string C, double O, double B, double D) Light)> Shadows =
        new(StringComparer.Ordinal)
    {
        // Dark drops are black; a light UI needs a violet-grey shadow or the panel looks dirty.
        ["Shadow1"] = (("#000000", 0.18, 12, 2), ("#141428", 0.08, 12, 2)),
        ["Shadow2"] = (("#000000", 0.28, 20, 4), ("#141428", 0.10, 20, 4)),
        ["Shadow3"] = (("#000000", 0.36, 32, 6), ("#141428", 0.14, 32, 6)),
    };

    // Tag chips: darkened in the light scheme so the chip's own text stays readable on white.
    private static readonly string[] TagsDark =
        { "#7C5CFF", "#5B8CFF", "#46C98B", "#E0894A", "#E05A8A", "#42B8C8", "#B07CF2", "#D0A92E" };
    private static readonly string[] TagsLight =
        { "#5B3FD6", "#2A5BD7", "#0B7A45", "#A65A16", "#B02860", "#0B6F7A", "#7A45C4", "#8A6A00" };

    // ------------------------------------------------------------------ readers

    public static IEnumerable<string> ColorKeys => Colors.Keys;
    public static IEnumerable<string> GradientKeys => Gradients.Keys;
    public static IEnumerable<string> ShadowKeys => Shadows.Keys;

    /// <summary>The named colour, in the requested scheme. Throws on an unknown key (typos are bugs,
    /// and a silently-transparent brush is the hardest kind of bug to see).</summary>
    public static Rgba Color(string key, bool dark)
    {
        if (!Colors.TryGetValue(key, out var pair))
            throw new ArgumentOutOfRangeException(nameof(key), key, "unknown design token");
        return Parse(dark ? pair.Dark : pair.Light);
    }

    public static (Rgba From, Rgba To) Gradient(string key, bool dark)
    {
        if (!Gradients.TryGetValue(key, out var g))
            throw new ArgumentOutOfRangeException(nameof(key), key, "unknown gradient token");
        return dark ? (Parse(g.D0), Parse(g.D1)) : (Parse(g.L0), Parse(g.L1));
    }

    public static bool IsVertical(string key) => Gradients[key].Vertical;

    public static (Rgba Color, double Opacity, double Blur, double Depth) Shadow(string key, bool dark)
    {
        if (!Shadows.TryGetValue(key, out var s))
            throw new ArgumentOutOfRangeException(nameof(key), key, "unknown shadow token");
        var v = dark ? s.Dark : s.Light;
        return (Parse(v.C), v.O, v.B, v.D);
    }

    public static string[] Tags(bool dark) => (string[])(dark ? TagsDark : TagsLight).Clone();

    /// <summary>Parse <c>#RRGGBB</c> or <c>#AARRGGBB</c>.</summary>
    public static Rgba Parse(string hex)
    {
        var s = (hex ?? "").Trim();
        if (s.StartsWith('#')) s = s[1..];
        if (s.Length == 8)
            return new Rgba(A: Byte(s, 0), R: Byte(s, 2), G: Byte(s, 4), B: Byte(s, 6));
        return new Rgba(255, Byte(s, 0), Byte(s, 2), Byte(s, 4));
    }

    private static byte Byte(string s, int at) => Convert.ToByte(s.Substring(at, 2), 16);
}
