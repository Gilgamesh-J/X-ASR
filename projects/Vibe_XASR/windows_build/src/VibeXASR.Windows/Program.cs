using System;
using System.Windows.Forms;

namespace VibeXASR.Windows;

/// <summary>
/// Entry point. Mirrors the macOS app's "menu-bar app, no main window" model:
/// we never show a primary form — only a tray icon, transient dialogs, and the
/// borderless overlay. <see cref="TrayApp"/> owns the engine, hotkey and overlay.
/// </summary>
internal static class Program
{
    [STAThread]
    private static void Main()
    {
        // .NET 8 WinForms bootstrap: high-DPI + default font in one call.
        // ApplicationConfiguration.Initialize() is source-generated from the
        // csproj <Application*> properties (HighDpiMode = PerMonitorV2).
        ApplicationConfiguration.Initialize();

        // Single-instance guard so two tray icons don't fight over the hotkey.
        using var single = new System.Threading.Mutex(initiallyOwned: true,
            "VibeXASR.Windows.SingleInstance", out bool isNew);
        if (!isNew)
        {
            // TODO(win): optionally signal the existing instance to show Settings.
            return;
        }

        Diag.Log("=== launch (VibeXASR " + Application.ProductVersion + ") ===");
        using var app = new TrayApp();
        app.Start();

        // Pump the WinForms message loop. TrayApp.Start() does NOT block; the
        // ApplicationContext keeps the process alive until Quit calls ExitThread.
        Application.Run(app.Context);
    }
}
