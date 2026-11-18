using System;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Animation;
using Point = System.Windows.Point;

namespace VibeXASR.Windows.Ui.Wpf;

/// <summary>
/// The app's single motion language (a Windows-tuned port of the macOS build's spring feel).
///
/// Rules every caller must respect:
///  • Only <see cref="UIElement.OpacityProperty"/> and <see cref="UIElement.RenderTransform"/> are animated —
///    never Width/Height/Top/Left/Margin (layout animation on a 45 ms timer + SizeToContent window is jank).
///  • One gesture never runs longer than <see cref="Slow"/> (240 ms).
///  • Every entry point clears the previous animation on the property first, so re-triggering mid-flight
///    snaps from the current value instead of queueing.
///  • <see cref="Enabled"/> is false when the user turned Windows animations off, on an RDP session, or with
///    VIBEXASR_NO_MOTION=1: every helper then applies the END state instantly (no animation object at all).
///  • On an AllowsTransparency window, animate the INNER root element's opacity — never Window.Opacity
///    (that makes the whole layered window flicker and can drop the drop-shadow).
/// </summary>
public static class Motion
{
    // ---------------- timing ----------------
    public static readonly TimeSpan Fast = TimeSpan.FromMilliseconds(120);   // hover / press / dismiss
    public static readonly TimeSpan Base = TimeSpan.FromMilliseconds(180);   // enter / state swap
    public static readonly TimeSpan Slow = TimeSpan.FromMilliseconds(240);   // large panels

    /// <summary>Durations for XAML storyboards (Styles.xaml): zero when motion is disabled.</summary>
    public static Duration DurFast => D(Fast);
    public static Duration DurBase => D(Base);
    private static Duration D(TimeSpan t) => Enabled ? new Duration(t) : new Duration(TimeSpan.Zero);

    // ---------------- easing ----------------
    public static readonly IEasingFunction EaseOut = new CubicEase { EasingMode = EasingMode.EaseOut };
    public static readonly IEasingFunction EaseIn = new CubicEase { EasingMode = EasingMode.EaseIn };
    public static readonly IEasingFunction EaseInOut = new CubicEase { EasingMode = EasingMode.EaseInOut };
    /// <summary>Gentle overshoot (BackEase, small amplitude) — used only for the toggle thumb.</summary>
    public static readonly IEasingFunction Spring = new BackEase { EasingMode = EasingMode.EaseOut, Amplitude = 0.35 };

    // ---------------- enablement ----------------
    private static bool? _enabled;

    /// <summary>True when animation should run. Cheap and cached; call <see cref="Reset"/> after changing the env var.</summary>
    public static bool Enabled
    {
        get
        {
            if (_enabled is { } cached) return cached;
            bool on = true;
            try
            {
                var env = Environment.GetEnvironmentVariable("VIBEXASR_NO_MOTION");
                if (!string.IsNullOrEmpty(env) && env != "0" && !env.Equals("false", StringComparison.OrdinalIgnoreCase)) on = false;
                if (on && !SystemParameters.ClientAreaAnimation) on = false;   // "Show animations in Windows"
                if (on && SystemParameters.IsRemoteSession) on = false;        // RDP: keep it instant
            }
            catch { /* never let a probe break the UI */ }
            _enabled = on;
            return on;
        }
    }

    public static void Reset() => _enabled = null;

    // ---------------- transforms ----------------
    /// <summary>Get (or install) the [scale, translate] pair this class animates. Both live in one
    /// TransformGroup so a pop and a slide can be composed without clobbering each other.</summary>
    private static (ScaleTransform scale, TranslateTransform move) Transforms(FrameworkElement el)
    {
        if (el.RenderTransform is TransformGroup g && g.Children.Count == 2
            && g.Children[0] is ScaleTransform s0 && g.Children[1] is TranslateTransform t0)
            return (s0, t0);

        var s = new ScaleTransform(1, 1);
        var t = new TranslateTransform(0, 0);
        var grp = new TransformGroup();
        grp.Children.Add(s);
        grp.Children.Add(t);
        el.RenderTransformOrigin = new Point(0.5, 0.5);
        el.RenderTransform = grp;
        return (s, t);
    }

    private static void ClearScale(ScaleTransform s)
    {
        s.BeginAnimation(ScaleTransform.ScaleXProperty, null);
        s.BeginAnimation(ScaleTransform.ScaleYProperty, null);
    }

    private static void ClearMove(TranslateTransform t) => t.BeginAnimation(TranslateTransform.YProperty, null);

    private static void ClearOpacity(UIElement el) => el.BeginAnimation(UIElement.OpacityProperty, null);

    // ---------------- opacity ----------------

    /// <summary>Fade to full opacity from wherever it is right now.
    /// Note the value discipline used by every helper here: the BASE value is set to the settled state
    /// and the animation runs from the captured visible value to it. So when the animation is later
    /// cleared (reset / re-trigger / window hidden), the element lands on its settled appearance
    /// instead of snapping back to a stale base.</summary>
    public static void FadeIn(UIElement? el, TimeSpan? dur = null, TimeSpan? delay = null, double to = 1)
    {
        if (el is null) return;
        double from = el.Opacity;          // effective (animated) value, read before the clock is removed
        ClearOpacity(el);
        el.Opacity = to;                   // base = settled state
        if (!Enabled) return;
        if (from >= to - 0.001) return;    // already there: don't schedule a no-op clock
        var a = new DoubleAnimation(from, to, new Duration(dur ?? Base)) { EasingFunction = EaseOut };
        if (delay is { } d && d > TimeSpan.Zero) a.BeginTime = d;
        el.BeginAnimation(UIElement.OpacityProperty, a);
    }

    /// <summary>Fade to zero, then run <paramref name="done"/> (hide/close the window there, not before).</summary>
    public static void FadeOut(UIElement? el, TimeSpan? dur = null, Action? done = null, TimeSpan? delay = null)
    {
        if (el is null) { done?.Invoke(); return; }
        double from = el.Opacity;
        ClearOpacity(el);
        el.Opacity = 0;                    // base = settled state (stays invisible if the clock is cleared)
        if (!Enabled) { done?.Invoke(); return; }
        var a = new DoubleAnimation(from, 0, new Duration(dur ?? Fast)) { EasingFunction = EaseIn };
        if (delay is { } d && d > TimeSpan.Zero) a.BeginTime = d;
        if (done is not null) a.Completed += (_, _) => done();
        el.BeginAnimation(UIElement.OpacityProperty, a);
    }

    // ---------------- pop (scale + fade) ----------------

    /// <summary>Enter: fade 0→1 while scaling <paramref name="from"/>→1. The default 0.96 is deliberately
    /// small — a pill that grows 4% reads as "it arrived", 15% reads as a toy.</summary>
    public static void PopIn(FrameworkElement? el, double from = 0.96, TimeSpan? dur = null, TimeSpan? delay = null)
    {
        if (el is null) return;
        var (s, _) = Transforms(el);
        ClearOpacity(el);
        ClearScale(s);
        el.Opacity = 1; s.ScaleX = 1; s.ScaleY = 1;   // base = settled state
        if (!Enabled) return;
        var d = new Duration(dur ?? Base);
        var f = new DoubleAnimation(from, 1, d) { EasingFunction = EaseOut };
        var o = new DoubleAnimation(0, 1, d) { EasingFunction = EaseOut };
        if (delay is { } dl && dl > TimeSpan.Zero) { f.BeginTime = dl; o.BeginTime = dl; }
        s.BeginAnimation(ScaleTransform.ScaleXProperty, f);
        s.BeginAnimation(ScaleTransform.ScaleYProperty, f);
        el.BeginAnimation(UIElement.OpacityProperty, o);
    }

    /// <summary>Exit: fade 1→0 while shrinking to <paramref name="to"/>, then run <paramref name="done"/>.</summary>
    public static void PopOut(FrameworkElement? el, double to = 0.97, TimeSpan? dur = null, Action? done = null)
    {
        if (el is null) { done?.Invoke(); return; }
        var (s, _) = Transforms(el);
        double from = el.Opacity;
        ClearOpacity(el);
        ClearScale(s);
        el.Opacity = 0; s.ScaleX = 1; s.ScaleY = 1;   // base = settled (invisible) state
        if (!Enabled) { done?.Invoke(); return; }
        var d = new Duration(dur ?? Fast);
        var f = new DoubleAnimation(to, d) { EasingFunction = EaseIn };
        var o = new DoubleAnimation(from, 0, d) { EasingFunction = EaseIn };
        o.Completed += (_, _) => done?.Invoke();
        s.BeginAnimation(ScaleTransform.ScaleXProperty, f);
        s.BeginAnimation(ScaleTransform.ScaleYProperty, f);
        el.BeginAnimation(UIElement.OpacityProperty, o);
    }

    // ---------------- slide (translate + fade) ----------------

    /// <summary>Enter from <paramref name="dy"/> px away (negative = from above) while fading in.</summary>
    public static void SlideIn(FrameworkElement? el, double dy = 8, TimeSpan? dur = null)
    {
        if (el is null) return;
        var (_, t) = Transforms(el);
        ClearOpacity(el);
        ClearMove(t);
        el.Opacity = 1; t.Y = 0;           // base = settled state
        if (!Enabled) return;
        var d = new Duration(dur ?? Base);
        t.BeginAnimation(TranslateTransform.YProperty, new DoubleAnimation(dy, 0, d) { EasingFunction = EaseOut });
        el.BeginAnimation(UIElement.OpacityProperty, new DoubleAnimation(0, 1, d) { EasingFunction = EaseOut });
    }

    /// <summary>Exit towards <paramref name="dy"/> px while fading out, then run <paramref name="done"/>.</summary>
    public static void SlideOut(FrameworkElement? el, double dy = 6, TimeSpan? dur = null, Action? done = null)
    {
        if (el is null) { done?.Invoke(); return; }
        var (_, t) = Transforms(el);
        double from = el.Opacity;
        ClearOpacity(el);
        ClearMove(t);
        el.Opacity = 0; t.Y = 0;          // base = settled (invisible) state
        if (!Enabled) { done?.Invoke(); return; }
        var d = new Duration(dur ?? Fast);
        t.BeginAnimation(TranslateTransform.YProperty, new DoubleAnimation(dy, d) { EasingFunction = EaseIn });
        var o = new DoubleAnimation(from, 0, d) { EasingFunction = EaseIn };
        o.Completed += (_, _) => done?.Invoke();
        el.BeginAnimation(UIElement.OpacityProperty, o);
    }

    // ---------------- interaction feedback ----------------

    /// <summary>Press feedback: scale down to 0.98 on mouse-down, back to 1 on release.</summary>
    public static void Press(FrameworkElement? el, bool down, double scale = 0.98)
        => ScaleTo(el, down ? scale : 1.0, Fast);

    /// <summary>Hover feedback for the small floating launcher (1.03 is enough at 152 px wide).</summary>
    public static void Hover(FrameworkElement? el, bool on, double scale = 1.03)
        => ScaleTo(el, on ? scale : 1.0, Base);

    private static void ScaleTo(FrameworkElement? el, double target, TimeSpan dur)
    {
        if (el is null) return;
        var (s, _) = Transforms(el);
        double from = s.ScaleX;            // effective value before the clock is removed
        ClearScale(s);
        s.ScaleX = s.ScaleY = target;      // base = settled state
        if (!Enabled) return;
        if (Math.Abs(from - target) < 0.0005) return;
        var a = new DoubleAnimation(from, target, new Duration(dur)) { EasingFunction = EaseOut };
        s.BeginAnimation(ScaleTransform.ScaleXProperty, a);
        s.BeginAnimation(ScaleTransform.ScaleYProperty, a);
    }

    /// <summary>Reset an element to its resting visual state (opacity 1, no scale/offset, no animations).</summary>
    public static void Reset(FrameworkElement? el)
    {
        if (el is null) return;
        ClearOpacity(el);
        el.Opacity = 1;
        if (el.RenderTransform is TransformGroup g && g.Children.Count == 2
            && g.Children[0] is ScaleTransform s && g.Children[1] is TranslateTransform t)
        {
            ClearScale(s); ClearMove(t);
            s.ScaleX = s.ScaleY = 1; t.Y = 0;
        }
    }
}
