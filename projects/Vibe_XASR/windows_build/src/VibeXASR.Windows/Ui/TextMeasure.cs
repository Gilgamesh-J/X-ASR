using System;
using System.Drawing;
using System.Windows.Forms;

namespace VibeXASR.Windows.Ui;

/// <summary>
/// Text measurement + colour maths shared by every WinForms surface.
///
/// These two helpers used to live on <c>SettingsForm</c>, a window that no longer exists: the live
/// screens (Onboarding, OnCall session, the old history panel) still called
/// <c>SettingsForm.MeasureWrapped</c> / <c>SettingsForm.Blend</c>, which is the only reason ~1,500
/// lines of dead window code kept compiling. Extracting them here is what lets those files go.
/// </summary>
public static class TextMeasure
{
    /// <summary>Height (px) of <paramref name="text"/> wrapped into <paramref name="width"/>, never
    /// less than one line of <paramref name="font"/>.</summary>
    public static int Wrapped(string text, Font font, int width)
    {
        if (string.IsNullOrEmpty(text)) return 0;
        var sz = TextRenderer.MeasureText(text, font, new Size(width, 0),
            TextFormatFlags.WordBreak | TextFormatFlags.TextBoxControl);
        return Math.Max(font.Height, sz.Height);
    }

    /// <summary>Linear mix of two colours: <paramref name="t"/> = 1 → <paramref name="a"/>.</summary>
    public static Color Blend(Color a, Color b, float t) => Color.FromArgb(
        (int)(a.R * t + b.R * (1 - t)),
        (int)(a.G * t + b.G * (1 - t)),
        (int)(a.B * t + b.B * (1 - t)));
}
