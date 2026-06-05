using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

namespace VibeXASR.Windows.Storage;

/// <summary>
/// API-key storage encrypted at rest with Windows DPAPI (per-user), mirroring macOS KeychainStore's
/// "encrypted on this machine only, never uploaded" guarantee. Stored as a DPAPI blob under
/// %APPDATA%\VibeXASR\secrets\&lt;account&gt;.bin — only the current Windows user can decrypt it.
/// Uses CryptProtectData/CryptUnprotectData via P/Invoke (no extra NuGet dependency).
/// </summary>
internal static class SecretStore
{
    private static string Dir => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "VibeXASR", "secrets");
    private static string PathFor(string account) => Path.Combine(Dir, account + ".bin");

    public static void Set(string account, string value)
    {
        try
        {
            Directory.CreateDirectory(Dir);
            var p = PathFor(account);
            if (string.IsNullOrEmpty(value)) { if (File.Exists(p)) File.Delete(p); return; }
            var blob = Protect(Encoding.UTF8.GetBytes(value));
            if (blob is not null) File.WriteAllBytes(p, blob);
        }
        catch { /* best-effort; a failed key write just means the user re-enters it */ }
    }

    public static string Get(string account)
    {
        try
        {
            var p = PathFor(account);
            if (!File.Exists(p)) return "";
            var clear = Unprotect(File.ReadAllBytes(p));
            return clear is null ? "" : Encoding.UTF8.GetString(clear);
        }
        catch { return ""; }
    }

    // ----- DPAPI P/Invoke -----

    [StructLayout(LayoutKind.Sequential)]
    private struct DATA_BLOB { public int cbData; public IntPtr pbData; }

    [DllImport("crypt32.dll", SetLastError = true, CharSet = CharSet.Auto)]
    private static extern bool CryptProtectData(ref DATA_BLOB pDataIn, string? szDataDescr, IntPtr pOptionalEntropy,
        IntPtr pvReserved, IntPtr pPromptStruct, int dwFlags, ref DATA_BLOB pDataOut);

    [DllImport("crypt32.dll", SetLastError = true, CharSet = CharSet.Auto)]
    private static extern bool CryptUnprotectData(ref DATA_BLOB pDataIn, IntPtr ppszDataDescr, IntPtr pOptionalEntropy,
        IntPtr pvReserved, IntPtr pPromptStruct, int dwFlags, ref DATA_BLOB pDataOut);

    [DllImport("kernel32.dll")] private static extern IntPtr LocalFree(IntPtr hMem);

    private const int CRYPTPROTECT_UI_FORBIDDEN = 0x1;

    private static byte[]? Protect(byte[] data)
    {
        var inBlob = ToBlob(data); var outBlob = new DATA_BLOB();
        try
        {
            if (!CryptProtectData(ref inBlob, "VibeXASR", IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, CRYPTPROTECT_UI_FORBIDDEN, ref outBlob))
                return null;
            return FromBlob(outBlob);
        }
        finally { Marshal.FreeHGlobal(inBlob.pbData); if (outBlob.pbData != IntPtr.Zero) LocalFree(outBlob.pbData); }
    }

    private static byte[]? Unprotect(byte[] data)
    {
        var inBlob = ToBlob(data); var outBlob = new DATA_BLOB();
        try
        {
            if (!CryptUnprotectData(ref inBlob, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, CRYPTPROTECT_UI_FORBIDDEN, ref outBlob))
                return null;
            return FromBlob(outBlob);
        }
        finally { Marshal.FreeHGlobal(inBlob.pbData); if (outBlob.pbData != IntPtr.Zero) LocalFree(outBlob.pbData); }
    }

    private static DATA_BLOB ToBlob(byte[] data)
    {
        var blob = new DATA_BLOB { cbData = data.Length, pbData = Marshal.AllocHGlobal(data.Length) };
        Marshal.Copy(data, 0, blob.pbData, data.Length);
        return blob;
    }

    private static byte[] FromBlob(DATA_BLOB blob)
    {
        var bytes = new byte[blob.cbData];
        Marshal.Copy(blob.pbData, bytes, 0, blob.cbData);
        return bytes;
    }
}
