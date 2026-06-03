using System;
using System.Collections.Generic;
using System.IO;
using VibeXASR.Windows.Storage;

namespace VibeXASR.Windows.Models;

/// <summary>
/// Resolves on-disk locations for the streaming zipformer2 transducer model files of a
/// given tier, plus the VAD model. Mirrors the macOS layout
/// (<c>chunk-&lt;T&gt;ms-model/{encoder,decoder,joiner}-&lt;T&gt;ms.onnx</c> + <c>tokens.txt</c>).
///
/// Files are resolved across TWO roots, in order:
///   1. <b>Writable</b>: <c>%APPDATA%\VibeXASR\models</c> — where on-demand tiers download.
///   2. <b>Bundled</b>:  <c>&lt;app dir&gt;\models</c> — models shipped by the installer
///      (read-only, like the macOS app's <c>Resources/</c>). The default 960 ms tier +
///      silero VAD live here, so a freshly installed app needs no download.
/// Reads prefer the writable copy (so a re-download wins); downloads always target the
/// writable root.
/// </summary>
public sealed class ModelPaths
{
    /// <summary>Tier chunk size in milliseconds (160 / 480 / 960 / 1920).</summary>
    public int TierMs { get; }

    /// <summary>Writable models root (download target): %APPDATA%/VibeXASR/models.</summary>
    public string WritableRoot { get; }

    /// <summary>Read-only models root shipped next to the executable by the installer.</summary>
    public string BundledRoot { get; }

    public ModelPaths(int tierMs, string? writableRoot = null, string? bundledRoot = null)
    {
        TierMs = tierMs;
        WritableRoot = writableRoot ?? Path.Combine(AppPaths.DataDir, "models");
        BundledRoot = bundledRoot ?? Path.Combine(AppContext.BaseDirectory, "models");
    }

    public static ModelPaths ForTier(ModelTier tier) => new((int)tier);

    /// <summary>Roots searched for an existing file, in priority order.</summary>
    private IEnumerable<string> Roots() { yield return WritableRoot; yield return BundledRoot; }

    /// <summary>First root that already contains <paramref name="rel"/>; else the writable path.</summary>
    private string Resolve(string rel)
    {
        foreach (var root in Roots())
        {
            var p = Path.Combine(root, rel);
            if (File.Exists(p)) return p;
        }
        return Path.Combine(WritableRoot, rel); // default = download target
    }

    private string TierRel(string file) => Path.Combine($"chunk-{TierMs}ms-model", file);

    /// <summary>Download target dir for this tier (always the writable root).</summary>
    public string TierDir => Path.Combine(WritableRoot, $"chunk-{TierMs}ms-model");

    public string Encoder => Resolve(TierRel($"encoder-{TierMs}ms.onnx"));
    public string Decoder => Resolve(TierRel($"decoder-{TierMs}ms.onnx"));
    public string Joiner  => Resolve(TierRel($"joiner-{TierMs}ms.onnx"));
    public string Tokens  => Resolve(TierRel("tokens.txt"));

    // VAD models: Silero is a single onnx at the models root; FireRed is a subdir holding the
    // onnx + CMVN files (matching the macOS firered/ layout).
    public string SileroVad  => Resolve("silero_vad.onnx");
    public string FireRedDir => ResolveDir("firered");

    // ---- Dictionary (词典) resources ----
    /// <summary>Augmented BPE vocab for hotword tokenization (bundled, tier-independent).</summary>
    public string BpeVocab => Resolve("bpe.vocab");
    /// <summary>汉字→拼音 table for homophone correction (bundled).</summary>
    public string PinyinTable => Resolve("pinyin.txt");
    /// <summary>User-edited hotwords file (writable root, written by HotwordsStore on rebuild).</summary>
    public string HotwordsFile => Path.Combine(WritableRoot, "hotwords.txt");

    /// <summary>First root whose <c>firered/</c> dir contains the model; else the writable root.</summary>
    private string ResolveDir(string rel)
    {
        foreach (var root in Roots())
        {
            var p = Path.Combine(root, rel);
            if (File.Exists(Path.Combine(p, "firered_vad.onnx"))) return p;
        }
        return Path.Combine(WritableRoot, rel);
    }

    /// <summary>The four files that must exist for the ASR engine to start at this tier.</summary>
    public IEnumerable<string> RequiredAsrFiles()
    {
        yield return Encoder;
        yield return Decoder;
        yield return Joiner;
        yield return Tokens;
    }

    public bool AsrModelPresent()
    {
        foreach (var f in RequiredAsrFiles())
            if (!File.Exists(f)) return false;
        return true;
    }

    public string VadFileFor(VadKind kind) =>
        kind == VadKind.Silero ? SileroVad : Path.Combine(FireRedDir, "firered_vad.onnx");

    public bool VadPresent(VadKind kind)
    {
        if (kind == VadKind.Silero) return File.Exists(SileroVad);
        var d = FireRedDir;   // FireRed needs the onnx + both CMVN files
        return File.Exists(Path.Combine(d, "firered_vad.onnx"))
            && File.Exists(Path.Combine(d, "cmvn_means.bin"))
            && File.Exists(Path.Combine(d, "cmvn_istd.bin"));
    }

    /// <summary>The VAD to actually use: the chosen one if present, else Silero. FireRed ships
    /// bundled (not downloadable), so a missing FireRed safely degrades to Silero.</summary>
    public VadKind ResolveVad(VadKind chosen) =>
        chosen == VadKind.FireRed && !VadPresent(VadKind.FireRed) ? VadKind.Silero : chosen;
}
