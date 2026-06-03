using System;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Threading;
using System.Windows.Forms;

namespace VibeXASR.Windows;

/// <summary>
/// Auto-update via WinSparkle — the Windows analog of the macOS Sparkle setup. Reads an
/// EdDSA-signed appcast on GitHub Pages; when a newer version is published it shows
/// WinSparkle's native UI to download + verify + run the per-user MSI (a MajorUpgrade, so
/// no UAC). On install WinSparkle launches the MSI and then asks us to quit so the running
/// .exe unlocks and can be replaced — same model as macOS Sparkle (appcast + Ed25519).
/// </summary>
internal static class Updater
{
    /// <summary>Windows appcast feed (GitHub Pages). Override for testing via VIBEXASR_APPCAST.</summary>
    private const string DefaultAppcastUrl = "https://liutaocode.github.io/Vibe_XASR/appcast-win.xml";

    /// <summary>EdDSA (Ed25519) public key — base64 of the 32-byte key from winsparkle-tool.
    /// The matching private key signs each released MSI and is NOT stored in the repo.</summary>
    private const string EdDsaPublicKey = "JDGHT12/JYeIOmylcEDxlzzNyqXB/f5223l3ORPfRRA=";

    private const string Dll = "WinSparkle";

    private static bool _inited;
    private static SynchronizationContext? _ui;
    private static Action? _onQuit;
    // Keep the delegates rooted for the process lifetime — the native side holds raw pointers.
    private static CanShutdownFn? _canShutdown;
    private static ShutdownRequestFn? _shutdownRequest;

    /// <summary>Initialize WinSparkle and start automatic (daily) update checks. Idempotent.</summary>
    public static void Initialize(SynchronizationContext? ui, Action onQuit)
    {
        if (_inited) return;
        _ui = ui;
        _onQuit = onQuit;
        try
        {
            NativeLoader.EnsureRegistered();

            var v = Assembly.GetExecutingAssembly().GetName().Version ?? new Version(1, 0, 0);
            // Include the 4th field (revision) so Windows patch suffixes (e.g. 1.1.3.1) compare
            // correctly against the appcast — WinSparkle does a 4-field version comparison.
            string version = $"{v.Major}.{v.Minor}.{Math.Max(0, v.Build)}.{Math.Max(0, v.Revision)}";
            string? env = Environment.GetEnvironmentVariable("VIBEXASR_APPCAST");
            string appcast = string.IsNullOrWhiteSpace(env) ? DefaultAppcastUrl : env;

            win_sparkle_set_appcast_url(appcast);
            win_sparkle_set_app_details("Vibe XASR", "Vibe XASR", version);
            win_sparkle_set_eddsa_public_key(EdDsaPublicKey);

            _canShutdown = () => 1;                // always safe to quit (no unsaved documents)
            _shutdownRequest = OnShutdownRequest;  // installer already launched → terminate app
            win_sparkle_set_can_shutdown_callback(_canShutdown);
            win_sparkle_set_shutdown_request_callback(_shutdownRequest);

            win_sparkle_set_automatic_check_for_updates(1);
            win_sparkle_set_update_check_interval(60 * 60 * 24); // daily

            win_sparkle_init();
            _inited = true;
            Diag.Log($"updater: init v={version} feed={appcast}");
        }
        catch (Exception ex)
        {
            Diag.Log("updater: init failed — " + ex.Message);
        }
    }

    /// <summary>Manual "检查更新" — shows WinSparkle's UI, including the "you're up to date" case.</summary>
    public static void CheckForUpdatesUi()
    {
        try
        {
            if (!_inited) { Diag.Log("updater: check requested before init"); return; }
            win_sparkle_check_update_with_ui();
        }
        catch (Exception ex) { Diag.Log("updater: check failed — " + ex.Message); }
    }

    /// <summary>Stop WinSparkle's helper threads on normal app shutdown.</summary>
    public static void Cleanup()
    {
        if (!_inited) return;
        try { win_sparkle_cleanup(); } catch { /* best-effort */ }
        _inited = false;
    }

    // WinSparkle has already launched the installer; quit gracefully so the .exe unlocks.
    private static void OnShutdownRequest()
    {
        Diag.Log("updater: shutdown requested (installing update)");
        try
        {
            if (_ui is not null && _onQuit is not null) _ui.Post(_ => _onQuit!(), null);
            else Application.Exit();
        }
        catch { Environment.Exit(0); }
    }

    // ---- P/Invoke (WinSparkle, all __cdecl) ----
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] private delegate int CanShutdownFn();
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] private delegate void ShutdownRequestFn();

    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)] private static extern void win_sparkle_init();
    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)] private static extern void win_sparkle_cleanup();
    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)] private static extern void win_sparkle_check_update_with_ui();
    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)] private static extern void win_sparkle_set_automatic_check_for_updates(int state);
    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)] private static extern void win_sparkle_set_update_check_interval(int interval);
    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl, CharSet = CharSet.Ansi)] private static extern void win_sparkle_set_appcast_url(string url);
    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl, CharSet = CharSet.Ansi)] private static extern int win_sparkle_set_eddsa_public_key(string pubkey);
    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl, CharSet = CharSet.Unicode)] private static extern void win_sparkle_set_app_details(string company, string app, string version);
    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)] private static extern void win_sparkle_set_can_shutdown_callback(CanShutdownFn cb);
    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)] private static extern void win_sparkle_set_shutdown_request_callback(ShutdownRequestFn cb);
}
