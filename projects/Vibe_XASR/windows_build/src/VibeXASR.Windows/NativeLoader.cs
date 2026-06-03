using System;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;

namespace VibeXASR.Windows;

/// <summary>
/// One process-wide <see cref="NativeLibrary.SetDllImportResolver"/> for our own bundled native
/// DLLs (WinSparkle, firered_vad). A single resolver is required — the API allows only one per
/// assembly — so both the updater and the VAD route through here. Loads each from the app's own
/// directory (next to the single-file exe / install dir); unknown names fall through to the
/// default search (so sherpa-onnx's own natives resolve normally).
/// </summary>
internal static class NativeLoader
{
    private static readonly string[] Known = { "WinSparkle", "firered_vad" };
    private static bool _registered;
    private static readonly object _gate = new();

    public static void EnsureRegistered()
    {
        lock (_gate)
        {
            if (_registered) return;
            _registered = true;
            NativeLibrary.SetDllImportResolver(typeof(NativeLoader).Assembly, Resolve);
        }
    }

    private static IntPtr Resolve(string name, Assembly asm, DllImportSearchPath? search)
    {
        foreach (var known in Known)
        {
            if (!name.Equals(known, StringComparison.OrdinalIgnoreCase)) continue;
            foreach (var dir in new[] { AppContext.BaseDirectory,
                                        Path.GetDirectoryName(Environment.ProcessPath ?? "") })
            {
                if (string.IsNullOrEmpty(dir)) continue;
                var p = Path.Combine(dir, known + ".dll");
                if (File.Exists(p) && NativeLibrary.TryLoad(p, out var h)) return h;
            }
        }
        return IntPtr.Zero; // not ours → default resolution
    }
}
