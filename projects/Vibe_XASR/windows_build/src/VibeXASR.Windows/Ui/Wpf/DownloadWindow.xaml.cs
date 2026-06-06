using System;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;
using VibeXASR.Windows.Storage;

namespace VibeXASR.Windows.Ui.Wpf;

/// <summary>Model-download progress dialog (WPF) shown on first launch or when switching to an
/// un-downloaded tier. Borderless rounded, centered, top-most — and unlike the old WinForms
/// DownloadForm, it has a Cancel button that aborts the in-flight download.</summary>
public partial class DownloadWindow : Window
{
    /// <summary>Raised on the UI thread when the user clicks Cancel.</summary>
    public event Action? CancelRequested;

    public DownloadWindow()
    {
        InitializeComponent();
        TitleText.Text = L10n.T("dl.title");
        CancelBtn.Content = L10n.T("cancel");
        CancelBtn.Click += (_, _) => { CancelBtn.IsEnabled = false; CancelBtn.Content = L10n.T("switching"); CancelRequested?.Invoke(); };
        SourceInitialized += (_, _) => DarkTitleBar();
    }

    /// <summary>Update progress (0..1) + a detail line. Safe to call from any thread.</summary>
    public void Report(double fraction, string detail)
    {
        if (!Dispatcher.CheckAccess()) { try { Dispatcher.BeginInvoke(() => Report(fraction, detail)); } catch { } return; }
        Track.UpdateLayout();
        Fill.Width = Math.Max(0, Track.ActualWidth * Math.Max(0, Math.Min(1, fraction)));
        DetailText.Text = detail;
    }

    [DllImport("dwmapi.dll")] private static extern int DwmSetWindowAttribute(IntPtr h, int attr, ref int v, int size);
    private void DarkTitleBar() { try { var h = new WindowInteropHelper(this).Handle; int on = 1; DwmSetWindowAttribute(h, 20, ref on, sizeof(int)); } catch { } }
}
