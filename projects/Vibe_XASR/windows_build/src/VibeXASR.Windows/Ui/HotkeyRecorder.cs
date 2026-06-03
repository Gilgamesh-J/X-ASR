using System;
using System.Collections.Generic;
using System.Drawing;
using System.Runtime.InteropServices;
using System.Windows.Forms;

namespace VibeXASR.Windows.Ui;

/// <summary>Win32 virtual-key → friendly name (analogue of the macOS Keycodes table).</summary>
public static class VkNames
{
    private static readonly Dictionary<int, string> Map = new()
    {
        [0xA3] = "Right Ctrl", [0xA2] = "Left Ctrl",
        [0xA1] = "Right Shift", [0xA0] = "Left Shift",
        [0xA5] = "Right Alt", [0xA4] = "Left Alt",
        [0x5C] = "Right ⊞ Win", [0x5B] = "Left ⊞ Win", [0x5D] = "Menu",
        [0x11] = "Ctrl", [0x10] = "Shift", [0x12] = "Alt",
        [0x14] = "Caps Lock", [0x20] = "Space", [0x09] = "Tab",
        [0x0D] = "Enter", [0x1B] = "Esc", [0x08] = "Backspace",
        [0x2D] = "Insert", [0x2E] = "Delete", [0x24] = "Home", [0x23] = "End",
        [0x21] = "Page Up", [0x22] = "Page Down",
        [0x90] = "Num Lock", [0x91] = "Scroll Lock", [0x2C] = "Print Screen",
        [0x25] = "←", [0x26] = "↑", [0x27] = "→", [0x28] = "↓",
    };

    public static string Name(int vk)
    {
        if (Map.TryGetValue(vk, out var n)) return n;
        if (vk >= 0x70 && vk <= 0x87) return "F" + (vk - 0x70 + 1);     // F1..F24
        if (vk >= 0x30 && vk <= 0x39) return ((char)vk).ToString();      // 0..9
        if (vk >= 0x41 && vk <= 0x5A) return ((char)vk).ToString();      // A..Z
        if (vk >= 0x60 && vk <= 0x69) return "Num " + (vk - 0x60);       // numpad 0..9
        return $"VK 0x{vk:X2}";
    }
}

/// <summary>
/// One-shot global key capture via a transient WH_KEYBOARD_LL hook. Used by the
/// settings hotkey recorder so we get the EXACT virtual-key — including left/right
/// modifier distinction (VK_RCONTROL vs VK_LCONTROL) that WM_KEYDOWN doesn't give.
/// </summary>
public sealed class KeyCaptureHook : IDisposable
{
    private const int WH_KEYBOARD_LL = 13;
    private const int WM_KEYDOWN = 0x0100, WM_SYSKEYDOWN = 0x0104;

    [StructLayout(LayoutKind.Sequential)]
    private struct KBDLLHOOKSTRUCT { public uint vkCode; public uint scanCode; public uint flags; public uint time; public IntPtr dwExtraInfo; }
    private delegate IntPtr Proc(int nCode, IntPtr wParam, IntPtr lParam);

    private readonly Proc _proc;
    private IntPtr _hook = IntPtr.Zero;

    /// <summary>Raised on the first key-down with the captured virtual-key code.</summary>
    public event Action<int>? Captured;

    public KeyCaptureHook() => _proc = Callback;

    public void Start()
    {
        if (_hook != IntPtr.Zero) return;
        using var proc = System.Diagnostics.Process.GetCurrentProcess();
        using var mod = proc.MainModule!;
        _hook = SetWindowsHookEx(WH_KEYBOARD_LL, _proc, GetModuleHandle(mod.ModuleName), 0);
    }

    private IntPtr Callback(int nCode, IntPtr wParam, IntPtr lParam)
    {
        if (nCode >= 0)
        {
            int msg = wParam.ToInt32();
            if (msg is WM_KEYDOWN or WM_SYSKEYDOWN)
            {
                var data = Marshal.PtrToStructure<KBDLLHOOKSTRUCT>(lParam);
                int vk = (int)data.vkCode;
                if (vk != 0x1B) // Esc cancels (handled by the recorder); don't bind it
                {
                    Captured?.Invoke(vk);
                    return (IntPtr)1; // swallow the binding keypress
                }
                Captured?.Invoke(0x1B);
                return (IntPtr)1;
            }
        }
        return CallNextHookEx(_hook, nCode, wParam, lParam);
    }

    public void Dispose()
    {
        if (_hook != IntPtr.Zero) { UnhookWindowsHookEx(_hook); _hook = IntPtr.Zero; }
    }

    [DllImport("user32.dll", SetLastError = true)]
    private static extern IntPtr SetWindowsHookEx(int idHook, Proc lpfn, IntPtr hMod, uint dwThreadId);
    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool UnhookWindowsHookEx(IntPtr hhk);
    [DllImport("user32.dll", SetLastError = true)]
    private static extern IntPtr CallNextHookEx(IntPtr hhk, int nCode, IntPtr wParam, IntPtr lParam);
    [DllImport("kernel32.dll", CharSet = CharSet.Auto, SetLastError = true)]
    private static extern IntPtr GetModuleHandle(string? lpModuleName);
}

/// <summary>
/// macOS-style "click to record" hotkey field. At rest it shows the bound key name in
/// a surface-2 pill; clicking arms a <see cref="KeyCaptureHook"/> and shows "Press a
/// key…"; the next key press binds (Esc cancels). Raises <see cref="HotkeyChanged"/>.
/// </summary>
internal sealed class HotkeyRecorder : Control
{
    private int _vk;
    private bool _recording;
    private KeyCaptureHook? _hook;

    public int Vk { get => _vk; set { _vk = value; Invalidate(); } }
    public event Action<int>? HotkeyChanged;

    public HotkeyRecorder()
    {
        DoubleBuffered = true;
        Cursor = Cursors.Hand;
        Font = Theme.Ui(10f);
        Size = new Size(150, 32);
        SetStyle(ControlStyles.SupportsTransparentBackColor, true);
        BackColor = Color.Transparent;
    }

    protected override void OnClick(EventArgs e)
    {
        if (_recording) return;
        _recording = true; Invalidate();
        _hook = new KeyCaptureHook();
        _hook.Captured += OnCaptured;
        _hook.Start();
        base.OnClick(e);
    }

    private void OnCaptured(int vk)
    {
        // Marshal back to the UI thread; the LL hook fires on the installing thread,
        // but BeginInvoke keeps us safe if that ever changes.
        if (IsHandleCreated) BeginInvoke(() => Finish(vk)); else Finish(vk);
    }

    private void Finish(int vk)
    {
        StopHook();
        _recording = false;
        if (vk != 0x1B && vk != 0) { _vk = vk; HotkeyChanged?.Invoke(vk); }
        Invalidate();
    }

    private void StopHook()
    {
        if (_hook is not null) { _hook.Captured -= OnCaptured; _hook.Dispose(); _hook = null; }
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        var g = e.Graphics; Draw.Hq(g);
        var r = new RectangleF(0, 0, Width, Height);
        Draw.FillRounded(g, r, Theme.RadiusControl, _recording ? Theme.AccentSoft : Theme.Surface2);
        Draw.StrokeRounded(g, r, Theme.RadiusControl, _recording ? Theme.AccentA : Theme.Hairline);
        string label = _recording ? L10n.T("dict.hotkey.recording") : VkNames.Name(_vk);
        TextRenderer.DrawText(g, label, Font, Rectangle.Round(r),
            _recording ? Theme.AccentA : Theme.Text,
            TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.NoPadding);
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing) StopHook();
        base.Dispose(disposing);
    }
}
