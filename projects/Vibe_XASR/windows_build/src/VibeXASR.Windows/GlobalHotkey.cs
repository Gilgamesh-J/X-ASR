using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Windows.Forms;

namespace VibeXASR.Windows;

/// <summary>
/// Global push-to-talk hotkey via a low-level keyboard hook (WH_KEYBOARD_LL).
///
/// We use a hook rather than RegisterHotKey because push-to-talk needs distinct
/// KeyDown / KeyUp (hold-to-talk), which RegisterHotKey does not provide. The hook sees every key
/// system-wide; we track modifier state live and match the configured trigger key + modifier combo
/// (macOS build 204 parity). It also matches extra per-template bindings so the Prompt Studio's
/// per-template hotkeys ride the same hook.
///
/// The hook callback runs on the thread that installed it, so install from the UI thread.
/// </summary>
public sealed class GlobalHotkey : IDisposable
{
    // Modifier bitfield (matches Settings.HotkeyMods): Ctrl=1, Alt=2, Shift=4, Win=8.
    public const int MOD_CTRL = 1, MOD_ALT = 2, MOD_SHIFT = 4, MOD_WIN = 8;

    private const int WH_KEYBOARD_LL = 13;
    private const int WM_KEYDOWN = 0x0100;
    private const int WM_KEYUP = 0x0101;
    private const int WM_SYSKEYDOWN = 0x0104;
    private const int WM_SYSKEYUP = 0x0105;

    private const int VK_LSHIFT = 0xA0, VK_RSHIFT = 0xA1, VK_LCONTROL = 0xA2, VK_RCONTROL = 0xA3;
    private const int VK_LMENU = 0xA4, VK_RMENU = 0xA5, VK_LWIN = 0x5B, VK_RWIN = 0x5C;

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

    private readonly LowLevelKeyboardProc _proc;
    private IntPtr _hookHandle = IntPtr.Zero;

    /// <summary>A trigger binding: a virtual key plus the modifier bitfield that must be held with it.</summary>
    public readonly record struct Binding(int Vk, int Mods);

    private Binding _primary;
    private List<(string Id, Binding B)> _templateBindings = new();

    // live modifier state
    private bool _lctrl, _rctrl, _lalt, _ralt, _lshift, _rshift, _lwin, _rwin;
    // currently-held trigger: null = none, "" = primary, else a template id
    private string? _activeDownId;

    /// <summary>Raised once when the primary trigger transitions up→down.</summary>
    public event EventHandler? KeyDown;
    /// <summary>Raised once when the primary trigger transitions down→up.</summary>
    public event EventHandler? KeyUp;
    /// <summary>Raised when a per-template binding goes down (carries the template id).</summary>
    public event EventHandler<string>? TemplateDown;
    /// <summary>Raised when the currently-held per-template binding goes up.</summary>
    public event EventHandler<string>? TemplateUp;

    public GlobalHotkey(int virtualKey, int mods = 0)
    {
        _primary = new Binding(virtualKey, mods);
        _proc = HookCallback;
    }

    /// <summary>Change the primary trigger (key + modifier combo) at runtime.</summary>
    public void SetKey(int virtualKey, int mods = 0)
    {
        Diag.Log($"GlobalHotkey.SetKey 0x{_primary.Vk:X2} -> 0x{virtualKey:X2}+m{mods} ({VibeXASR.Windows.Ui.VkNames.Name(virtualKey)})");
        _primary = new Binding(virtualKey, mods);
        _activeDownId = null;
    }

    /// <summary>Replace the per-template hotkey bindings (Prompt Studio). Empty = none.</summary>
    public void SetTemplateBindings(IEnumerable<(string Id, int Vk, int Mods)> bindings)
    {
        _templateBindings = new List<(string, Binding)>();
        foreach (var (id, vk, mods) in bindings)
            if (vk != 0) _templateBindings.Add((id, new Binding(vk, mods)));
    }

    public void Install()
    {
        if (_hookHandle != IntPtr.Zero) return;
        using var curProcess = System.Diagnostics.Process.GetCurrentProcess();
        using var curModule = curProcess.MainModule!;
        IntPtr hMod = GetModuleHandle(curModule.ModuleName);
        _hookHandle = SetWindowsHookEx(WH_KEYBOARD_LL, _proc, hMod, 0);
        if (_hookHandle == IntPtr.Zero)
            throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error(), "Failed to install WH_KEYBOARD_LL hook.");
        Diag.Log($"GlobalHotkey installed (vk=0x{_primary.Vk:X2}+m{_primary.Mods}, handle={_hookHandle})");
    }

    private int CurMods =>
        ((_lctrl || _rctrl) ? MOD_CTRL : 0) | ((_lalt || _ralt) ? MOD_ALT : 0) |
        ((_lshift || _rshift) ? MOD_SHIFT : 0) | ((_lwin || _rwin) ? MOD_WIN : 0);

    private const int VK_SHIFT = 0x10, VK_CONTROL = 0x11, VK_MENU = 0x12;   // generic (some drivers/remappers)
    private static int OwnModBit(int vk) => vk switch
    {
        VK_LCONTROL or VK_RCONTROL or VK_CONTROL => MOD_CTRL,
        VK_LMENU or VK_RMENU or VK_MENU => MOD_ALT,
        VK_LSHIFT or VK_RSHIFT or VK_SHIFT => MOD_SHIFT,
        VK_LWIN or VK_RWIN => MOD_WIN,
        _ => 0,
    };

    /// <summary>Does this key-press match the binding? The trigger key's own modifier contribution is
    /// excluded, so a bare modifier (e.g. Right Ctrl, mods=0) still matches.</summary>
    private bool Matches(int vk, Binding b)
    {
        if (vk != b.Vk) return false;
        int effective = CurMods & ~OwnModBit(vk);
        return effective == b.Mods;
    }

    private void UpdateModifierState(int vk, bool down)
    {
        switch (vk)
        {
            case VK_LCONTROL: case VK_CONTROL: _lctrl = down; break;
            case VK_RCONTROL: _rctrl = down; break;
            case VK_LMENU: case VK_MENU: _lalt = down; break;
            case VK_RMENU: _ralt = down; break;
            case VK_LSHIFT: case VK_SHIFT: _lshift = down; break;
            case VK_RSHIFT: _rshift = down; break;
            case VK_LWIN: _lwin = down; break;
            case VK_RWIN: _rwin = down; break;
        }
    }

    private IntPtr HookCallback(int nCode, IntPtr wParam, IntPtr lParam)
    {
        if (nCode >= 0)
        {
            var data = Marshal.PtrToStructure<KBDLLHOOKSTRUCT>(lParam);
            int msg = wParam.ToInt32();
            int vk = (int)data.vkCode;
            // Ignore SYNTHETIC (injected) key events — e.g. our own TextInserter.ClearModifiers() releases
            // Ctrl/Alt/Shift via SendInput while inserting; without this guard the hook reads that injected
            // modifier-UP as the user releasing the trigger and stops dictation mid-utterance.
            const uint LLKHF_INJECTED = 0x10;
            if ((data.flags & LLKHF_INJECTED) != 0) return CallNextHookEx(_hookHandle, nCode, wParam, lParam);
            bool isDown = msg is WM_KEYDOWN or WM_SYSKEYDOWN;
            bool isUp = msg is WM_KEYUP or WM_SYSKEYUP;

            // keep modifier state current BEFORE matching (so a modifier-as-trigger works)
            if (isDown) UpdateModifierState(vk, true);
            else if (isUp) UpdateModifierState(vk, false);

            if (isDown && _activeDownId is null)
            {
                if (Matches(vk, _primary))
                {
                    _activeDownId = "";
                    Diag.Log($"hotkey DOWN vk=0x{vk:X2}+m{_primary.Mods}");
                    KeyDown?.Invoke(this, EventArgs.Empty);
                    if (ShouldSwallow(_primary)) return (IntPtr)1;
                }
                else
                {
                    foreach (var (id, b) in _templateBindings)
                        if (Matches(vk, b))
                        {
                            _activeDownId = id;
                            Diag.Log($"template hotkey DOWN id={id} vk=0x{vk:X2}+m{b.Mods}");
                            TemplateDown?.Invoke(this, id);
                            if (ShouldSwallow(b)) return (IntPtr)1;
                            break;
                        }
                }
            }
            else if (isUp && _activeDownId is not null)
            {
                // release on the trigger key's own up (ignore modifiers releasing first)
                bool releasedPrimary = _activeDownId == "" && vk == _primary.Vk;
                bool releasedTemplate = _activeDownId != "" && _templateBindings.Exists(t => t.Id == _activeDownId && t.B.Vk == vk);
                if (releasedPrimary)
                {
                    _activeDownId = null;
                    KeyUp?.Invoke(this, EventArgs.Empty);
                }
                else if (releasedTemplate)
                {
                    var id = _activeDownId!;
                    _activeDownId = null;
                    TemplateUp?.Invoke(this, id);
                }
            }
        }
        return CallNextHookEx(_hookHandle, nCode, wParam, lParam);
    }

    /// <summary>Swallow the trigger key (don't pass it on) when it's a printable key or a combo, so it
    /// doesn't also type/trigger its normal action. A bare modifier (mods=0, modifier key) passes through.</summary>
    private static bool ShouldSwallow(Binding b) => b.Mods != 0 || OwnModBit(b.Vk) == 0;

    public void Uninstall()
    {
        if (_hookHandle != IntPtr.Zero)
        {
            UnhookWindowsHookEx(_hookHandle);
            _hookHandle = IntPtr.Zero;
        }
    }

    public void Dispose() => Uninstall();

    [DllImport("user32.dll", SetLastError = true)]
    private static extern IntPtr SetWindowsHookEx(int idHook, LowLevelKeyboardProc lpfn, IntPtr hMod, uint dwThreadId);

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool UnhookWindowsHookEx(IntPtr hhk);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern IntPtr CallNextHookEx(IntPtr hhk, int nCode, IntPtr wParam, IntPtr lParam);

    [DllImport("kernel32.dll", CharSet = CharSet.Auto, SetLastError = true)]
    private static extern IntPtr GetModuleHandle(string? lpModuleName);
}
