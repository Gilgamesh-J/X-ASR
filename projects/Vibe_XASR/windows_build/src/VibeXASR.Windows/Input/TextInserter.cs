using System;
using System.Runtime.InteropServices;
using System.Threading;

namespace VibeXASR.Windows.Input;

/// <summary>
/// Inserts text at the focused app's caret using SendInput with KEYEVENTF_UNICODE.
///
/// This is the Windows equivalent of the macOS "type unicode, clear modifiers" inserter:
/// we synthesize each character as a Unicode key event (vk=0, scan=codepoint) rather than
/// translating to virtual keys. That means a held push-to-talk MODIFIER (e.g. Right Ctrl)
/// won't turn the injected characters into shortcuts — KEYEVENTF_UNICODE bypasses the
/// keyboard layout and modifier state entirely.
///
/// We still defensively release modifiers before injecting (some apps look at async key
/// state), mirroring the macOS "clear modifiers" step.
/// </summary>
public static class TextInserter
{
    /// <summary>Insert a whole string at the caret (Paste mode, or a chunk in Type mode).</summary>
    public static void InsertText(string text)
    {
        if (string.IsNullOrEmpty(text)) return;

        ClearModifiers();

        // One INPUT per UTF-16 code unit, key-down + key-up. Surrogate pairs are sent as
        // two consecutive UNICODE events, which Windows recombines into the astral codepoint.
        var inputs = new INPUT[text.Length * 2];
        int n = 0;
        foreach (char c in text)
        {
            inputs[n++] = MakeUnicode(c, keyUp: false);
            inputs[n++] = MakeUnicode(c, keyUp: true);
        }

        SendBatch(inputs, n);
    }

    /// <summary>
    /// Send <paramref name="count"/> backspaces — used by Type mode to retract characters
    /// when the streaming hypothesis shrinks/changes (diff against last emitted text).
    /// </summary>
    public static void Backspace(int count)
    {
        if (count <= 0) return;
        ClearModifiers();

        var inputs = new INPUT[count * 2];
        int n = 0;
        for (int i = 0; i < count; i++)
        {
            inputs[n++] = MakeVk(VK_BACK, keyUp: false);
            inputs[n++] = MakeVk(VK_BACK, keyUp: true);
        }
        SendBatch(inputs, n);
    }

    // ---- internals ----

    private static void SendBatch(INPUT[] inputs, int count)
    {
        if (count == 0) return;
        // SendInput is atomic per call; sending the whole batch at once avoids interleaving
        // with real user input. TODO(win): for very long inserts consider chunking + a tiny
        // Thread.Sleep so slow apps (terminals) keep up.
        uint sent = SendInput((uint)count, inputs, Marshal.SizeOf<INPUT>());
        if (sent != (uint)count)
        {
            // TODO(win): SendInput can be blocked by UIPI (elevated target) or input desktop
            // switches. Log Marshal.GetLastWin32Error(); surface to tray.
        }
    }

    private static void ClearModifiers()
    {
        // Force-release the common modifiers so a held PTT key / stray Shift doesn't alter
        // injected input. We send key-UP events for each; harmless if already up.
        ReadOnlySpan<ushort> mods = stackalloc ushort[]
        {
            VK_LSHIFT, VK_RSHIFT, VK_LCONTROL, VK_RCONTROL,
            VK_LMENU, VK_RMENU, VK_LWIN, VK_RWIN,
        };
        var inputs = new INPUT[mods.Length];
        for (int i = 0; i < mods.Length; i++)
            inputs[i] = MakeVk(mods[i], keyUp: true);
        SendInput((uint)inputs.Length, inputs, Marshal.SizeOf<INPUT>());
    }

    private static INPUT MakeUnicode(char c, bool keyUp) => new()
    {
        type = INPUT_KEYBOARD,
        U = new InputUnion
        {
            ki = new KEYBDINPUT
            {
                wVk = 0,
                wScan = c,
                dwFlags = KEYEVENTF_UNICODE | (keyUp ? KEYEVENTF_KEYUP : 0),
                time = 0,
                dwExtraInfo = IntPtr.Zero,
            }
        }
    };

    private static INPUT MakeVk(ushort vk, bool keyUp) => new()
    {
        type = INPUT_KEYBOARD,
        U = new InputUnion
        {
            ki = new KEYBDINPUT
            {
                wVk = vk,
                wScan = 0,
                dwFlags = keyUp ? KEYEVENTF_KEYUP : 0,
                time = 0,
                dwExtraInfo = IntPtr.Zero,
            }
        }
    };

    // ---- Win32 SendInput interop ----

    private const int INPUT_KEYBOARD = 1;
    private const uint KEYEVENTF_KEYUP = 0x0002;
    private const uint KEYEVENTF_UNICODE = 0x0004;

    private const ushort VK_BACK = 0x08;
    private const ushort VK_LSHIFT = 0xA0, VK_RSHIFT = 0xA1;
    private const ushort VK_LCONTROL = 0xA2, VK_RCONTROL = 0xA3;
    private const ushort VK_LMENU = 0xA4, VK_RMENU = 0xA5;
    private const ushort VK_LWIN = 0x5B, VK_RWIN = 0x5C;

    [StructLayout(LayoutKind.Sequential)]
    private struct INPUT
    {
        public int type;
        public InputUnion U;
    }

    [StructLayout(LayoutKind.Explicit)]
    private struct InputUnion
    {
        [FieldOffset(0)] public MOUSEINPUT mi;
        [FieldOffset(0)] public KEYBDINPUT ki;
        [FieldOffset(0)] public HARDWAREINPUT hi;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct KEYBDINPUT
    {
        public ushort wVk;
        public ushort wScan;
        public uint dwFlags;
        public uint time;
        public IntPtr dwExtraInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct MOUSEINPUT
    {
        public int dx;
        public int dy;
        public uint mouseData;
        public uint dwFlags;
        public uint time;
        public IntPtr dwExtraInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct HARDWAREINPUT
    {
        public uint uMsg;
        public ushort wParamL;
        public ushort wParamH;
    }

    // TODO(win): verify SendInput signature/marshalling on your SDK. cbSize must equal
    // sizeof(INPUT) for the running architecture (struct packing differs x64 vs arm64? no —
    // both are 64-bit LLP64, layout is identical, but confirm).
    [DllImport("user32.dll", SetLastError = true)]
    private static extern uint SendInput(uint nInputs,
        [MarshalAs(UnmanagedType.LPArray)] INPUT[] pInputs, int cbSize);
}
