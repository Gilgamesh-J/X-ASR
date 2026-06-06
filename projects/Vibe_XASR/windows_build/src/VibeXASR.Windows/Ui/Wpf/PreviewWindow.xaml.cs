using System;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Media;

namespace VibeXASR.Windows.Ui.Wpf;

public partial class PreviewWindow : Window
{
    public PreviewWindow()
    {
        InitializeComponent();
        SourceInitialized += (_, _) => ApplyChrome();
        // Dev self-capture: VIBEXASR_SHOT=<png> → render the WPF content to that file + exit
        // (GDI/PrintWindow can't capture WPF's hardware surface; RenderTargetBitmap can).
        Loaded += (_, _) =>
        {
            var shot = Environment.GetEnvironmentVariable("VIBEXASR_SHOT");
            if (string.IsNullOrEmpty(shot)) return;
            Dispatcher.BeginInvoke(System.Windows.Threading.DispatcherPriority.Loaded, new Action(() =>
            {
                try
                {
                    int w = (int)Math.Ceiling(ActualWidth), h = (int)Math.Ceiling(ActualHeight);
                    var rtb = new System.Windows.Media.Imaging.RenderTargetBitmap(w, h, 96, 96, PixelFormats.Pbgra32);
                    rtb.Render(this);
                    var enc = new System.Windows.Media.Imaging.PngBitmapEncoder();
                    enc.Frames.Add(System.Windows.Media.Imaging.BitmapFrame.Create(rtb));
                    using var fs = System.IO.File.Create(shot);
                    enc.Save(fs);
                }
                catch { }
                System.Windows.Application.Current?.Shutdown();
            }));
        };
    }

    [DllImport("dwmapi.dll")]
    private static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);

    private const int DWMWA_USE_IMMERSIVE_DARK_MODE = 20;
    private const int DWMWA_SYSTEMBACKDROP_TYPE = 38;   // Win11 22H2+
    private const int DWMSBT_MAINWINDOW = 2;             // Mica

    private void ApplyChrome()
    {
        try
        {
            var hwnd = new WindowInteropHelper(this).Handle;
            int dark = 1; DwmSetWindowAttribute(hwnd, DWMWA_USE_IMMERSIVE_DARK_MODE, ref dark, sizeof(int));
            _ = DWMWA_SYSTEMBACKDROP_TYPE; _ = DWMSBT_MAINWINDOW;   // (Mica backdrop disabled — was blanking the client)
        }
        catch { /* pre-Win11 — solid dark is fine */ }
    }
}
