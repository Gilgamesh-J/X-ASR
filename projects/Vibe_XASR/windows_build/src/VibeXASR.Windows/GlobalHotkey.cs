using System;
using System.Runtime.InteropServices;
using System.Windows.Forms;

namespace VibeXASR.Windows;

/// <summary>
/// Global push-to-talk hotkey via a low-level keyboard hook (WH_KEYBOARD_LL).
///
/// We use a hook rather than RegisterHotKey because push-to-talk needs distinct
/// KeyDown / KeyUp (hold-to-talk), which RegisterHotKey does not provide — it only
/// fires WM_HOTKEY on press. The hook sees every key system-wide; we filter to the
/// configured virtual-key and raise KeyDown once per physical press (suppressing
/// auto-repeat) and KeyUp on release.
///
/// The hook callback runs on the thread that installed it, so install from the UI
/// thread (the WinForms message loop pumps it).
/// </summary>
public sealed class GlobalHotkey : IDisposable
{
    private const int WH_KEYBOARD_LL = 13;
    private const int WM_KEYDOWN = 0x0100;
    private const int WM_KEYUP = 0x0101;
    private const int WM_SYSKEYDOWN = 0x0104;
    private const int WM_SYSKEYUP = 0x0105;

    [StructLayout(LayoutKind.Sequential)]
    private struct KBDLLHOOKSTRUCT
    {
        public uint vkCode;
        public uint scanCode;
        public uint flags;
        public uint time;
        public IntPtr dwExtraInfo;
    }

    private delegate IntPtr LowLevelKeyboardProc(int nCode, IntPtr wParam, IntPtr lParam);

    // Keep a managed ref so the delegate isn't GC'd while the unmanaged hook holds it.
    private readonly LowLevelKeyboardProc _proc;
    private IntPtr _hookHandle = IntPtr.Zero;

    private int _vk;
    private bool _isDown; // suppress auto-repeat KeyDown spam

    /// <summary>Raised once when the configured key transitions up->down.</summary>
    public event EventHandler? KeyDown;

    /// <summary>Raised once when the configured key transitions down->up.</summary>
    public event EventHandler? KeyUp;

    public GlobalHotkey(int virtualKey)
    {
        _vk = virtualKey;
        _proc = HookCallback;
    }

    /// <summary>Change the watched key at runtime (e.g. from Settings).</summary>
    public void SetKey(int virtualKey)
    {
        Diag.Log($"GlobalHotkey.SetKey 0x{_vk:X2} -> 0x{virtualKey:X2} ({VibeXASR.Windows.Ui.VkNames.Name(virtualKey)})");
        _vk = virtualKey;
        _isDown = false; // drop any stale held-state from the previous key
    }

    public void Install()
    {
        if (_hookHandle != IntPtr.Zero) return;

        // TODO(win): SetWindowsHookEx for a global LL hook wants a module handle. Passing the
        // module handle of the current process (or IntPtr.Zero) works for LL hooks because
        // they're not injected. Verify on Windows; some guidance uses GetModuleHandle(null).
        using var curProcess = System.Diagnostics.Process.GetCurrentProcess();
        using var curModule = curProcess.MainModule!;
        IntPtr hMod = GetModuleHandle(curModule.ModuleName);

        _hookHandle = SetWindowsHookEx(WH_KEYBOARD_LL, _proc, hMod, 0);
        if (_hookHandle == IntPtr.Zero)
            throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error(),
                "Failed to install WH_KEYBOARD_LL hook.");
        Diag.Log($"GlobalHotkey installed (vk=0x{_vk:X2}, handle={_hookHandle})");
    }

    private IntPtr HookCallback(int nCode, IntPtr wParam, IntPtr lParam)
    {
        if (nCode >= 0)
        {
            var data = Marshal.PtrToStructure<KBDLLHOOKSTRUCT>(lParam);
            int msg = wParam.ToInt32();

            if ((int)data.vkCode == _vk)
            {
                if (msg is WM_KEYDOWN or WM_SYSKEYDOWN)
                {
                    if (!_isDown)
                    {
                        _isDown = true;
                        Diag.Log($"hotkey DOWN vk=0x{_vk:X2}");
                        // Marshal back onto the UI thread happens naturally because the hook
                        // runs on the installing (UI) thread. Raise directly.
                        KeyDown?.Invoke(this, EventArgs.Empty);
                    }
                    // NOTE: we do NOT swallow the key (return CallNextHookEx) so the user's
                    // chosen modifier still works elsewhere. TODO(win): decide whether to
                    // suppress it (return (IntPtr)1) so the PTT key doesn't also trigger its
                    // normal action. macOS swallows the key while held — match that if desired.
                }
                else if (msg is WM_KEYUP or WM_SYSKEYUP)
                {
                    if (_isDown)
                    {
                        _isDown = false;
                        KeyUp?.Invoke(this, EventArgs.Empty);
                    }
                }
            }
        }
        return CallNextHookEx(_hookHandle, nCode, wParam, lParam);
    }

    public void Uninstall()
    {
        if (_hookHandle != IntPtr.Zero)
        {
            UnhookWindowsHookEx(_hookHandle);
            _hookHandle = IntPtr.Zero;
        }
    }

    public void Dispose() => Uninstall();

    // ---- P/Invoke ----
    // TODO(win): verify these signatures compile against your SDK; CharSet/SetLastError
    // attributes matter for the module-handle and last-error retrieval above.

    [DllImport("user32.dll", SetLastError = true)]
    private static extern IntPtr SetWindowsHookEx(int idHook, LowLevelKeyboardProc lpfn,
        IntPtr hMod, uint dwThreadId);

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool UnhookWindowsHookEx(IntPtr hhk);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern IntPtr CallNextHookEx(IntPtr hhk, int nCode, IntPtr wParam, IntPtr lParam);

    [DllImport("kernel32.dll", CharSet = CharSet.Auto, SetLastError = true)]
    private static extern IntPtr GetModuleHandle(string? lpModuleName);
}
