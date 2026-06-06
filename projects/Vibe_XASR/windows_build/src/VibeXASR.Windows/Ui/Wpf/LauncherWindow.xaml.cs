using System;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Threading;
using VibeXASR.Windows.Storage;
using Point = System.Windows.Point;
using MouseEventArgs = System.Windows.Input.MouseEventArgs;
using MouseButtonEventArgs = System.Windows.Input.MouseButtonEventArgs;
using Brush = System.Windows.Media.Brush;

namespace VibeXASR.Windows.Ui.Wpf;

/// <summary>A small draggable always-on-top "launcher" pill so users can always find + open the app
/// (the tray icon is easy to lose). Shows live status (ready / listening / loading); drag to move
/// (position persisted); hover shows ✕ to dismiss; click opens the tray quick-menu.</summary>
public partial class LauncherWindow : Window
{
    private readonly IAppController _app;
    private Settings S => _app.Settings;
    private readonly DispatcherTimer _poll = new() { Interval = TimeSpan.FromMilliseconds(500) };

    private Point _dragStart;
    private bool _dragging, _moved;

    public LauncherWindow(IAppController app)
    {
        _app = app;
        InitializeComponent();
        SourceInitialized += (_, _) => { NoActivate(); PlaceFromSettings(); };
        Loaded += (_, _) => UpdateStatus();
        _poll.Tick += (_, _) => UpdateStatus();
        _poll.Start();
        Closed += (_, _) => _poll.Stop();

        MouseEnter += (_, _) => CloseBtn.Visibility = Visibility.Visible;
        MouseLeave += (_, _) => { if (!_dragging) CloseBtn.Visibility = Visibility.Collapsed; };

        // drag vs click on the pill body
        Pill.MouseLeftButtonDown += OnDown;
        Pill.MouseMove += OnMove;
        Pill.MouseLeftButtonUp += OnUp;

        CloseBtn.MouseLeftButtonUp += (_, e) => { e.Handled = true; _app.SetLauncherEnabled(false); };
    }

    private void OnDown(object sender, MouseButtonEventArgs e)
    {
        _dragging = true; _moved = false;
        _dragStart = PointToScreen(e.GetPosition(this));
        Pill.CaptureMouse();
    }

    private void OnMove(object sender, MouseEventArgs e)
    {
        if (!_dragging) return;
        var now = PointToScreen(e.GetPosition(this));
        var dx = now.X - _dragStart.X; var dy = now.Y - _dragStart.Y;
        if (!_moved && Math.Abs(dx) + Math.Abs(dy) < 4) return;   // below threshold = still a click
        _moved = true;
        // PointToScreen is in device px; convert delta to DIPs via the window's DPI.
        var src = PresentationSource.FromVisual(this);
        double sx = src?.CompositionTarget?.TransformFromDevice.M11 ?? 1.0;
        double sy = src?.CompositionTarget?.TransformFromDevice.M22 ?? 1.0;
        Left += dx * sx; Top += dy * sy;
        _dragStart = now;
    }

    private void OnUp(object sender, MouseButtonEventArgs e)
    {
        if (!_dragging) return;
        _dragging = false; Pill.ReleaseMouseCapture();
        if (_moved)
        {
            S.LauncherX = Left; S.LauncherY = Top; try { S.Save(); } catch { }
        }
        else
        {
            // a click → open the quick menu near the launcher (its top-right corner)
            var p = PointToScreen(new Point(ActualWidth, 0));
            var src = PresentationSource.FromVisual(this);
            double sx = src?.CompositionTarget?.TransformFromDevice.M11 ?? 1.0;
            _app.ShowQuickMenu(p.X * sx, (PointToScreen(new Point(0, 0)).Y) * sx);
        }
    }

    private void UpdateStatus()
    {
        bool ready = _app.EngineReady, listening = _app.IsListening;
        Dot.Fill = (Brush)FindResource(!ready ? "Warn" : listening ? "AccentA" : "Success");
        if (listening && Ring.Visibility != Visibility.Visible)
        {
            Ring.Visibility = Visibility.Visible;
            var grow = new DoubleAnimation(1, 2.4, TimeSpan.FromSeconds(1.1)) { RepeatBehavior = RepeatBehavior.Forever };
            var fade = new DoubleAnimation(0.55, 0, TimeSpan.FromSeconds(1.1)) { RepeatBehavior = RepeatBehavior.Forever };
            RingScale.BeginAnimation(ScaleTransform.ScaleXProperty, grow);
            RingScale.BeginAnimation(ScaleTransform.ScaleYProperty, grow);
            Ring.BeginAnimation(OpacityProperty, fade);
        }
        else if (!listening && Ring.Visibility == Visibility.Visible)
        {
            RingScale.BeginAnimation(ScaleTransform.ScaleXProperty, null);
            RingScale.BeginAnimation(ScaleTransform.ScaleYProperty, null);
            Ring.BeginAnimation(OpacityProperty, null);
            Ring.Visibility = Visibility.Collapsed;
        }
    }

    private void PlaceFromSettings()
    {
        UpdateLayout();
        var wa = SystemParameters.WorkArea;
        if (S.LauncherX is not double lx || S.LauncherY is not double ly)
        {
            Left = wa.Right - ActualWidth - 16;   // default: bottom-right, above the tray popup
            Top = wa.Bottom - ActualHeight - 56;
        }
        else
        {
            Left = Math.Max(wa.Left, Math.Min(lx, wa.Right - ActualWidth));
            Top = Math.Max(wa.Top, Math.Min(ly, wa.Bottom - ActualHeight));
        }
    }

    // never steal focus / never show in alt-tab
    private const int GWL_EXSTYLE = -20, WS_EX_NOACTIVATE = 0x08000000, WS_EX_TOOLWINDOW = 0x00000080;
    [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW")] private static extern IntPtr GetWindowLongPtr(IntPtr h, int i);
    [DllImport("user32.dll", EntryPoint = "SetWindowLongPtrW")] private static extern IntPtr SetWindowLongPtr(IntPtr h, int i, IntPtr v);
    private void NoActivate()
    {
        var h = new WindowInteropHelper(this).Handle;
        long ex = GetWindowLongPtr(h, GWL_EXSTYLE).ToInt64() | WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW;
        SetWindowLongPtr(h, GWL_EXSTYLE, new IntPtr(ex));
    }
}
