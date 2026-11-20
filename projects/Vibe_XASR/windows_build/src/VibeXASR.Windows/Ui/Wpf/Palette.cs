using System;
using System.Collections.Generic;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Effects;

// The project enables ImplicitUsings, which brings in System.Drawing (WinForms). Both it and
// System.Windows.Media define Brush/Color/Brushes, so the WPF ones have to win explicitly.
using Brush = System.Windows.Media.Brush;
using Color = System.Windows.Media.Color;
using Brushes = System.Windows.Media.Brushes;
using Point = System.Windows.Point;

namespace VibeXASR.Windows.Ui.Wpf;

/// <summary>
/// The WPF face of <see cref="DesignTokens"/>: it turns the shared colour table into one
/// <see cref="ResourceDictionary"/> of frozen brushes (plus gradients and shadows).
///
/// Why this file exists: the palette used to be copy-pasted six times (Styles.xaml plus five
/// code-built windows, each with its own literal hex table), and every copy was dark-only. The app
/// therefore rendered a dark UI next to light WinForms dialogs on a light-mode machine.
///
/// Now every token is declared once in <see cref="DesignTokens"/> and handed to WPF as a single
/// dictionary. XAML consumes it with <c>{DynamicResource Key}</c>; code consumes it with
/// <see cref="Get"/>. Switching schemes swaps the dictionary, so already-loaded windows re-resolve
/// their DynamicResource lookups without being recreated.
/// </summary>
public static class Palette
{
    /// <summary>True when the dark scheme is active.</summary>
    public static bool Dark { get; private set; } = true;

    /// <summary>The dictionary currently handed to WPF. Replaced wholesale on <see cref="Apply"/>.</summary>
    public static ResourceDictionary Current { get; private set; } = Build(true);

    /// <summary>Raised after a scheme swap so code-built surfaces can rebuild themselves.</summary>
    public static event Action? Changed;

    private static readonly List<WeakReference<FrameworkElement>> Attached = new();

    // ------------------------------------------------------------------ attach / apply

    /// <summary>Merge the palette into an element's resources (call once, after InitializeComponent).</summary>
    public static void Attach(FrameworkElement element)
    {
        if (element.Resources.Contains("AccentA")) return;         // already has a palette merged
        element.Resources.MergedDictionaries.Insert(0, Current);
        Attached.Add(new WeakReference<FrameworkElement>(element));
        Prune();
    }

    /// <summary>Switch scheme. Every attached element gets the new dictionary merged in place.</summary>
    public static void Apply(bool dark)
    {
        if (dark == Dark && Current.Count > 0) return;
        Dark = dark;
        Current = Build(dark);
        foreach (var a in Attached.ToArray())
        {
            if (!a.TryGetTarget(out var el)) continue;
            Replace(el);
        }
        Prune();
        Changed?.Invoke();
    }

    /// <summary>Re-apply the current scheme (e.g. after a language/rebuild) without changing it.</summary>
    public static void Refresh()
    {
        var fresh = Build(Dark);
        Current = fresh;
        foreach (var a in Attached.ToArray())
        {
            if (!a.TryGetTarget(out var el)) continue;
            Replace(el);
        }
        Prune();
    }

    private static void Replace(FrameworkElement el)
    {
        var md = el.Resources.MergedDictionaries;
        for (int i = 0; i < md.Count; i++)
        {
            // any previously-attached palette is identifiable by the token it always declares
            if (md[i].Contains("AccentA")) { md[i] = Current; return; }
        }
        md.Insert(0, Current);
    }

    private static void Prune()
    {
        for (int i = Attached.Count - 1; i >= 0; i--)
            if (!Attached[i].TryGetTarget(out _)) Attached.RemoveAt(i);
    }

    // ------------------------------------------------------------------ lookups

    public static Brush Get(string key) => Current[key] as Brush ?? Brushes.Transparent;

    public static Color Col(string key) => Get(key) is SolidColorBrush s ? s.Color : Colors.Transparent;

    /// <summary>Same colour at a new alpha — the hover/hairlines in code-built surfaces need this.</summary>
    public static Color WithA(Color c, byte a) => Color.FromArgb(a, c.R, c.G, c.B);

    public static Brush Alpha(string key, byte a) => new SolidColorBrush(WithA(Col(key), a));

    public static Color Hex(string hex)
    {
        var c = DesignTokens.Parse(hex);
        return Color.FromArgb(c.A, c.R, c.G, c.B);
    }

    /// <summary>Tag colours, darkened for the light scheme so a chip's text stays readable.</summary>
    public static string[] TagColors => DesignTokens.Tags(Dark);

    // ------------------------------------------------------------------ building

    private static ResourceDictionary Build(bool d)
    {
        var r = new ResourceDictionary();

        foreach (var key in DesignTokens.ColorKeys)
            r[key] = Brush(ToColor(DesignTokens.Color(key, d)));

        foreach (var key in DesignTokens.GradientKeys)
        {
            var (from, to) = DesignTokens.Gradient(key, d);
            r[key] = Gradient(ToColor(from), ToColor(to), DesignTokens.IsVertical(key));
        }

        foreach (var key in DesignTokens.ShadowKeys)
        {
            var (c, opacity, blur, depth) = DesignTokens.Shadow(key, d);
            r[key] = Shadow(ToColor(c), opacity, blur, depth);
        }

        return r;
    }

    private static Color ToColor(Rgba c) => Color.FromArgb(c.A, c.R, c.G, c.B);

    private static Brush Brush(Color c) { var b = new SolidColorBrush(c); b.Freeze(); return b; }

    private static LinearGradientBrush Gradient(Color from, Color to, bool vertical)
    {
        var g = new LinearGradientBrush(from, to, vertical ? 90 : 45);
        g.Freeze();
        return g;
    }

    private static DropShadowEffect Shadow(Color color, double opacity, double blur, double depth)
    {
        var e = new DropShadowEffect { Color = color, Opacity = opacity, BlurRadius = blur, ShadowDepth = depth, Direction = 270 };
        e.Freeze();
        return e;
    }
}
