using System;
using System.IO;
using System.Text;

namespace VibeXASR.Windows.Refine;

/// <summary>
/// Makes the CPM5 refiner GGUF loadable by LLamaSharp 0.27's bundled llama.cpp.
///
/// The model on the CDN was quantized with a newer llama.cpp and tags its tokenizer with
/// <c>tokenizer.ggml.pre = "minicpm5"</c>. LLamaSharp 0.27 (llama.cpp ad93962) doesn't know that
/// pre-tokenizer and aborts vocab load ("unknown pre-tokenizer type: 'minicpm5'"). The minicpm5
/// regex is identical to <c>qwen2</c> except for digit grouping, so we rewrite that ONE metadata
/// string to "qwen2" — the model then loads and behaves the same on Chinese text (verified: 上午十点→10:00,
/// fillers stripped). This keeps a single canonical model on the CDN (shared with macOS, whose own
/// llama.cpp knows minicpm5) and patches only the local Windows copy after download.
///
/// GGUF v3 layout:  [header][kv pairs][tensor infos][pad to alignment][tensor data]. Tensor-info offsets
/// are RELATIVE to the (aligned) data-section start, so we keep the tensor infos + tensor data
/// byte-identical and only (a) swap the KV string and (b) recompute the alignment pad. (C# port of
/// tools/patch_gguf_pre.py; output is byte-identical to it.)
/// </summary>
internal static class GgufPatcher
{
    private const string OldPre = "minicpm5";
    private const string NewPre = "qwen2";

    // GGUF metadata value type ids.
    private const uint U8 = 0, I8 = 1, U16 = 2, I16 = 3, U32 = 4, I32 = 5, F32 = 6, BOOL = 7,
                       STRING = 8, ARRAY = 9, U64 = 10, I64 = 11, F64 = 12;

    /// <summary>Ensure the GGUF at <paramref name="path"/> loads on the bundled llama.cpp. Cheap when already
    /// compatible (reads only the header). Returns true if the file is now loadable (patched or already so);
    /// false only on a parse/IO error. Idempotent + safe to call before every load.</summary>
    public static bool EnsureWindowsCompatible(string path)
    {
        try
        {
            var pre = ReadPreTokenizer(path);
            if (pre is null) return false;                 // not a GGUF we understand → let the loader report it
            if (pre != OldPre) return true;                // already qwen2 (or some other known type) → nothing to do
            RewritePre(path);
            Diag.Log($"GgufPatcher: rewrote tokenizer.ggml.pre {OldPre}→{NewPre} in {Path.GetFileName(path)}");
            return true;
        }
        catch (Exception ex) { Diag.Log("GgufPatcher.EnsureWindowsCompatible: " + ex.Message); return false; }
    }

    // ---- cheap front-scan: read tokenizer.ggml.pre without touching the tensor data ----

    private static string? ReadPreTokenizer(string path)
    {
        using var fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read);
        using var r = new BinaryReader(fs, Encoding.UTF8, leaveOpen: true);
        if (r.ReadUInt32() != 0x46554747u) return null;    // "GGUF" little-endian
        uint version = r.ReadUInt32();
        if (version != 3) return null;
        r.ReadUInt64();                                    // tensor_count
        ulong nKv = r.ReadUInt64();
        for (ulong i = 0; i < nKv; i++)
        {
            string key = ReadGgufString(r);
            uint vtype = r.ReadUInt32();
            if (key == "tokenizer.ggml.pre" && vtype == STRING) return ReadGgufString(r);
            SkipValue(r, vtype);
        }
        return null;
    }

    private static string ReadGgufString(BinaryReader r)
    {
        ulong len = r.ReadUInt64();
        var bytes = r.ReadBytes(checked((int)len));
        return Encoding.UTF8.GetString(bytes);
    }

    private static void SkipValue(BinaryReader r, uint vtype)
    {
        switch (vtype)
        {
            case U8: case I8: case BOOL: r.BaseStream.Seek(1, SeekOrigin.Current); break;
            case U16: case I16: r.BaseStream.Seek(2, SeekOrigin.Current); break;
            case U32: case I32: case F32: r.BaseStream.Seek(4, SeekOrigin.Current); break;
            case U64: case I64: case F64: r.BaseStream.Seek(8, SeekOrigin.Current); break;
            case STRING: { ulong n = r.ReadUInt64(); r.BaseStream.Seek(checked((long)n), SeekOrigin.Current); break; }
            case ARRAY:
                {
                    uint et = r.ReadUInt32();
                    ulong cnt = r.ReadUInt64();
                    if (et == STRING) { for (ulong j = 0; j < cnt; j++) { ulong n = r.ReadUInt64(); r.BaseStream.Seek(checked((long)n), SeekOrigin.Current); } }
                    else r.BaseStream.Seek(checked((long)FixedSize(et) * (long)cnt), SeekOrigin.Current);
                    break;
                }
            default: throw new InvalidDataException($"unsupported gguf value type {vtype}");
        }
    }

    private static int FixedSize(uint t) => t switch
    {
        U8 or I8 or BOOL => 1,
        U16 or I16 => 2,
        U32 or I32 or F32 => 4,
        U64 or I64 or F64 => 8,
        _ => throw new InvalidDataException($"non-fixed gguf type {t}"),
    };

    // ---- full rewrite (only when pre == minicpm5): swap the string + re-align the data section ----

    private static void RewritePre(string path)
    {
        var buf = File.ReadAllBytes(path);
        int p = 0;
        ulong RdU64() { var v = BitConverter.ToUInt64(buf, p); p += 8; return v; }
        uint RdU32() { var v = BitConverter.ToUInt32(buf, p); p += 4; return v; }
        string RdStr() { ulong n = RdU64(); var s = Encoding.UTF8.GetString(buf, p, (int)n); p += (int)n; return s; }

        p = 4;                                  // skip "GGUF"
        if (RdU32() != 3) throw new InvalidDataException("only GGUF v3 supported");
        ulong nTensors = RdU64();
        ulong nKv = RdU64();

        int alignment = 32;
        int preValStart = -1, preValEnd = -1;
        for (ulong i = 0; i < nKv; i++)
        {
            string key = RdStr();
            uint vtype = RdU32();
            if (key == "general.alignment" && vtype == U32) { alignment = (int)RdU32(); continue; }
            if (key == "tokenizer.ggml.pre" && vtype == STRING)
            {
                preValStart = p;
                string val = RdStr();
                if (val != OldPre) throw new InvalidDataException($"expected pre={OldPre}, found {val}");
                preValEnd = p;
                continue;
            }
            SkipValueBuf(buf, ref p, vtype);
        }
        if (preValStart < 0) throw new InvalidDataException("tokenizer.ggml.pre not found");

        // walk tensor infos to find where the info section ends (→ old data-section start, after alignment)
        for (ulong i = 0; i < nTensors; i++)
        {
            RdStr();                            // name
            uint nDim = RdU32();
            p += 8 * (int)nDim;                 // dims (u64 each)
            p += 4;                             // ggml type
            p += 8;                             // offset
        }
        int infosEnd = p;
        int oldDataStart = AlignUp(infosEnd, alignment);

        // rebuild: [head .. pre value] | new string | [rest of kv+infos] | new pad | tensor data
        var newVal = Encoding.UTF8.GetBytes(NewPre);
        var newStr = new byte[8 + newVal.Length];
        BitConverter.GetBytes((ulong)newVal.Length).CopyTo(newStr, 0);
        newVal.CopyTo(newStr, 8);

        int headLen = preValStart;
        int middleLen = infosEnd - preValEnd;
        int newInfosEnd = headLen + newStr.Length + middleLen;
        int newDataStart = AlignUp(newInfosEnd, alignment);
        int padLen = newDataStart - newInfosEnd;

        var tmp = path + ".tmp";
        using (var outFs = new FileStream(tmp, FileMode.Create, FileAccess.Write, FileShare.None))
        {
            outFs.Write(buf, 0, headLen);                       // header + kv up to the pre value
            outFs.Write(newStr, 0, newStr.Length);             // "qwen2" (len-prefixed)
            outFs.Write(buf, preValEnd, middleLen);            // rest of kv + all tensor infos (unchanged)
            for (int i = 0; i < padLen; i++) outFs.WriteByte(0);
            outFs.Write(buf, oldDataStart, buf.Length - oldDataStart);   // tensor data (verbatim)
        }
        File.Delete(path);
        File.Move(tmp, path);
    }

    private static void SkipValueBuf(byte[] buf, ref int p, uint vtype)
    {
        switch (vtype)
        {
            case U8: case I8: case BOOL: p += 1; break;
            case U16: case I16: p += 2; break;
            case U32: case I32: case F32: p += 4; break;
            case U64: case I64: case F64: p += 8; break;
            case STRING: { ulong n = BitConverter.ToUInt64(buf, p); p += 8 + (int)n; break; }
            case ARRAY:
                {
                    uint et = BitConverter.ToUInt32(buf, p); p += 4;
                    ulong cnt = BitConverter.ToUInt64(buf, p); p += 8;
                    if (et == STRING) { for (ulong j = 0; j < cnt; j++) { ulong n = BitConverter.ToUInt64(buf, p); p += 8 + (int)n; } }
                    else p += FixedSize(et) * (int)cnt;
                    break;
                }
            default: throw new InvalidDataException($"unsupported gguf value type {vtype}");
        }
    }

    private static int AlignUp(int v, int a) => (v + a - 1) / a * a;
}
