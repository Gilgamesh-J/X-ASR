using System;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Media.Animation;
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
        Palette.Attach(this);
        TitleText.Text = L10n.T("dl.title");
        CancelBtn.Content = L10n.T("cancel");
        CancelBtn.Click += (_, _) => { CancelBtn.IsEnabled = false; CancelBtn.Content = L10n.T("switching"); CancelRequested?.Invoke(); };
        SourceInitialized += (_, _) => DarkTitleBar();
        Loaded += (_, _) => { if (Content is FrameworkElement root) Motion.PopIn(root, 0.97, Motion.Base); };
    }

    /// <summary>Update progress (0..1) + a detail line. Safe to call from any thread.</summary>
    public void Report(double fraction, string detail)
    {
        if (!Dispatcher.CheckAccess()) { try { Dispatcher.BeginInvoke(() => Report(fraction, detail)); } catch { } return; }
        double f = Math.Max(0, Math.Min(1, fraction));
        // The fill spans the whole track (HorizontalAlignment=Stretch), so ScaleX alone is the progress
        // value: no ActualWidth to read, no layout pass per report.
        // Read the LIVE value while the previous clock is still running, then clear it and write the new
        // value as the base (Motion's rule: base holds the end state). Chaining from the live value keeps
        // a burst of reports gliding instead of jumping forward to the previous target each time.
        double from = FillScale.ScaleX;
        FillScale.BeginAnimation(System.Windows.Media.ScaleTransform.ScaleXProperty, null);
        FillScale.ScaleX = f;
        if (Motion.Enabled && Math.Abs(f - from) > 0.002)
        {
            FillScale.BeginAnimation(System.Windows.Media.ScaleTransform.ScaleXProperty,
                new DoubleAnimation(from, f, new Duration(Motion.Fast)) { EasingFunction = Motion.EaseOut });
        }
        DetailText.Text = detail;
    }
    private void DarkTitleBar() => Theme.ApplyDarkTitleBar(new WindowInteropHelper(this).Handle);
}