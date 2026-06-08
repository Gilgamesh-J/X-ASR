using System;
using System.Runtime.InteropServices;

namespace VibeXASR.Windows.Lexicon;

/// <summary>
/// Simplified→Traditional Chinese (简体→繁體) character conversion using the native Win32
/// <c>LCMapStringEx</c> transform with <c>LCMAP_TRADITIONAL_CHINESE</c>. This is the Windows
/// equivalent of the macOS app's ICU <c>kCFStringTransform...</c> / NSString variant — no bundled
/// conversion table, the OS does the mapping. Conversion is character-level (1:1 in length), so it is
/// safe to apply even mid-stream in Type mode.
/// </summary>
public static class Hant
{
    private const uint LCMAP_TRADITIONAL_CHINESE = 0x04000000;

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern int LCMapStringEx(
        string? lpLocaleName, uint dwMapFlags,
        string lpSrcStr, int cchSrc,
        char[]? lpDestStr, int cchDest,
        IntPtr lpVersionInformation, IntPtr lpReserved, IntPtr sortHandle);

    /// <summary>Convert simplified Chinese to traditional. Returns the input unchanged on any failure
    /// (non-CJK text passes through untouched anyway).</summary>
    public static string ToTraditional(string? s)
    {
        if (string.IsNullOrEmpty(s)) return s ?? string.Empty;
        try
        {
            // "zh-CN" gives the transform a Chinese sorting/casing context; the flag drives the
            // 简→繁 mapping. cchSrc = -1 lets the API include the NUL; we size the dest to the source
            // length (the mapping is 1:1 for these characters).
            var dest = new char[s.Length + 1];
            int n = LCMapStringEx("zh-CN", LCMAP_TRADITIONAL_CHINESE, s, s.Length, dest, dest.Length,
                IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
            if (n <= 0) return s;
            return new string(dest, 0, n);
        }
        catch
        {
            return s;
        }
    }
}
