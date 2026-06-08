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
        // OEM / punctuation keys (US layout glyphs) — so combos like Alt+. show ".", not "VK 0xBE"
        [0xBA] = ";", [0xBB] = "=", [0xBC] = ",", [0xBD] = "-", [0xBE] = ".", [0xBF] = "/",
        [0xC0] = "`", [0xDB] = "[", [0xDC] = "\\", [0xDD] = "]", [0xDE] = "'",
        // numpad operators
        [0x6A] = "Num *", [0x6B] = "Num +", [0x6D] = "Num -", [0x6E] = "Num .", [0x6F] = "Num /",
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

    /// <summary>"Ctrl+Alt+X" — modifier prefix (bitfield Ctrl=1,Alt=2,Shift=4,Win=8) + the key name.</summary>
    public static string Combo(int vk, int mods)
    {
        var p = "";
        if ((mods & 1) != 0) p += "Ctrl+";
        if ((mods & 2) != 0) p += "Alt+";
        if ((mods & 4) != 0) p += "Shift+";
        if ((mods & 8) != 0) p += "Win+";
        return p + Name(vk);
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
    private const int WM_KEYDOWN = 0x0100, WM_SYSKEYDOWN = 0x0104, WM_KEYUP = 0x0101, WM_SYSKEYUP = 0x0105;

    [StructLayout(LayoutKind.Sequential)]
    private struct KBDLLHOOKSTRUCT { public uint vkCode; public uint scanCode; public uint flags; public uint time; public IntPtr dwExtraInfo; }
    private delegate IntPtr Proc(int nCode, IntPtr wParam, IntPtr lParam);

    private readonly Proc _proc;
    private IntPtr _hook = IntPtr.Zero;
    private readonly bool _combo;

    /// <summary>Raised on the first key-down with the captured virtual-key code (single-key mode).</summary>
    public event Action<int>? Captured;
    /// <summary>Raised with (vk, mods) when a combo is captured (combo mode): a normal key with the held
    /// modifiers, or a bare modifier on its release. Esc → (0x1B, 0). Mods bitfield: Ctrl1/Alt2/Shift4/Win8.</summary>
    public event Action<int, int>? CapturedCombo;

    // live modifier state (combo mode)
    private bool _lc, _rc, _la, _ra, _ls, _rs, _lw, _rw;
    private bool _captured;   // one-shot guard: once captured, swallow the rest, fire nothing more
    private int CurMods => ((_lc || _rc) ? 1 : 0) | ((_la || _ra) ? 2 : 0) | ((_ls || _rs) ? 4 : 0) | ((_lw || _rw) ? 8 : 0);
    // macOS processAny parity: modifier-down is only a CANDIDATE. _heldOrder = the modifier vks pressed
    // (ordered; first = primary, keeps L/R); _peakMods = the OR of all held modifier bits. A modifier
    // alone never ends recording (else ⌥1-style combos could never be recorded — the ⌥ press would end it).
    private readonly System.Collections.Generic.List<int> _heldOrder = new();
    private int _peakMods;

    /// <param name="combo">true → capture vk+modifier combos (fires <see cref="CapturedCombo"/>);
    /// false → legacy single-key capture (fires <see cref="Captured"/>).</param>
    public KeyCaptureHook(bool combo = false) { _combo = combo; _proc = Callback; }

    public void Start()
    {
        if (_hook != IntPtr.Zero) return;
        using var proc = System.Diagnostics.Process.GetCurrentProcess();
        using var mod = proc.MainModule!;
        _hook = SetWindowsHookEx(WH_KEYBOARD_LL, _proc, GetModuleHandle(mod.ModuleName), 0);
    }

    private const int VK_SHIFT = 0x10, VK_CONTROL = 0x11, VK_MENU = 0x12;   // generic (some drivers/remappers send these)
    private const int VK_LSHIFT = 0xA0, VK_RSHIFT = 0xA1, VK_LCTRL = 0xA2, VK_RCTRL = 0xA3, VK_LALT = 0xA4, VK_RALT = 0xA5, VK_LWIN = 0x5B, VK_RWIN = 0x5C;
    private static int ModBit(int vk) => vk switch
    {
        VK_LCTRL or VK_RCTRL or VK_CONTROL => 1,
        VK_LALT or VK_RALT or VK_MENU => 2,
        VK_LSHIFT or VK_RSHIFT or VK_SHIFT => 4,
        VK_LWIN or VK_RWIN => 8,
        _ => 0,
    };
    private void UpdateMod(int vk, bool down)
    {
        switch (vk)
        {
            case VK_LCTRL: case VK_CONTROL: _lc = down; break; case VK_RCTRL: _rc = down; break;
            case VK_LALT: case VK_MENU: _la = down; break; case VK_RALT: _ra = down; break;
            case VK_LSHIFT: case VK_SHIFT: _ls = down; break; case VK_RSHIFT: _rs = down; break;
            case VK_LWIN: _lw = down; break; case VK_RWIN: _rw = down; break;
        }
    }

    private IntPtr Callback(int nCode, IntPtr wParam, IntPtr lParam)
    {
        if (nCode >= 0)
        {
            int msg = wParam.ToInt32();
            var data = Marshal.PtrToStructure<KBDLLHOOKSTRUCT>(lParam);
            int vk = (int)data.vkCode;
            bool down = msg is WM_KEYDOWN or WM_SYSKEYDOWN, up = msg is WM_KEYUP or WM_SYSKEYUP;

            if (_combo)
            {
                if (_captured) return (IntPtr)1;   // already fired once — swallow the trailing key events
                if (down)
                {
                    if (vk == 0x1B) { _captured = true; CapturedCombo?.Invoke(0x1B, 0); return (IntPtr)1; }   // Esc cancels
                    int mb = ModBit(vk);
                    if (mb != 0)
                    {
                        // modifier down = candidate only (don't finish — that's how ⌥1 / Ctrl+Alt get recorded)
                        UpdateMod(vk, true);
                        if (!_heldOrder.Contains(vk)) _heldOrder.Add(vk);
                        _peakMods |= mb;
                        return (IntPtr)1;
                    }
                    // a normal key → single key (mods=0) or modifier+key combo (mods=held).
                    // Skip the BARE activation/nav keys that armed us (Enter/Space click, Tab) — keep waiting.
                    if (CurMods == 0 && (vk == 0x0D || vk == 0x20 || vk == 0x09)) return (IntPtr)1;
                    _captured = true;
                    VibeXASR.Windows.Diag.Log($"hkrec CAPTURE key vk=0x{vk:X2} mods={CurMods}");
                    CapturedCombo?.Invoke(vk, CurMods);
                    return (IntPtr)1;
                }
                if (up)
                {
                    int mb = ModBit(vk);
                    UpdateMod(vk, false);
                    // a modifier was RELEASED with no normal key pressed → finalize from the peak:
                    //   1 held → pure single modifier (e.g. Right Ctrl);  ≥2 held → modifier combo (Ctrl+Alt).
                    if (mb != 0 && _heldOrder.Count >= 1)
                    {
                        int primary = _heldOrder[0];
                        int mods = _heldOrder.Count >= 2 ? (_peakMods & ~ModBit(primary)) : 0;
                        _captured = true;
                        VibeXASR.Windows.Diag.Log($"hkrec CAPTURE mod primary=0x{primary:X2} mods={mods} held={_heldOrder.Count}");
                        CapturedCombo?.Invoke(primary, mods);
                        return (IntPtr)1;
                    }
                    return (IntPtr)1;
                }
                return (IntPtr)1;   // swallow everything while recording
            }

            // legacy single-key mode
            if (down)
            {
                if (vk != 0x1B) { Captured?.Invoke(vk); return (IntPtr)1; }
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
