using System;
using System.Collections.Generic;
using System.Formats.Tar;
using System.IO;
using System.IO.Compression;
using System.Net.Http;
using System.Threading;
using System.Threading.Tasks;

namespace VibeXASR.Windows.Models;

/// <summary>Where model files come from. Mirrors macOS ModelDownloadSource (build 203).</summary>
public enum ModelDownloadSource
{
    /// <summary>CDN 加速线路 (Cloudflare R2). Per-tier int8-quantized gzip archive (~130 MB), extracted locally. Default.</summary>
    Official,
    /// <summary>ModelScope loose files (full precision, ~615 MB). Faster than HF in most CN regions.</summary>
    ModelScope,
    /// <summary>HuggingFace loose files (full precision, ~615 MB).</summary>
    HuggingFace,
}

public static class ModelSourceX
{
    public static ModelDownloadSource From(string? s) => s switch
    {
        "modelscope" => ModelDownloadSource.ModelScope,
        "huggingface" => ModelDownloadSource.HuggingFace,
        _ => ModelDownloadSource.Official,
    };
    public static string ToCode(ModelDownloadSource s) => s switch
    {
        ModelDownloadSource.ModelScope => "modelscope",
        ModelDownloadSource.HuggingFace => "huggingface",
        _ => "official",
    };
    /// <summary>Per-tier archive size hint (quantized) vs loose full-precision.</summary>
    public static bool IsQuantized(ModelDownloadSource s) => s == ModelDownloadSource.Official;
}

/// <summary>Progress callback payload for a single file (or archive) download.</summary>
public readonly record struct DownloadProgress(
    string FileName,
    long BytesReceived,
    long? TotalBytes,
    int FileIndex,
    int FileCount)
{
    public double? Fraction => TotalBytes is > 0 ? (double)BytesReceived / TotalBytes.Value : null;
}

/// <summary>
/// Downloads the per-tier streaming model. Three sources (macOS parity, build 203):
///   • Official  — CDN 加速线路 (R2): one int8-quantized gzip archive per tier,
///                 https://models.speech.wiki/asr/chunk-&lt;T&gt;ms.tar.gz, extracted to the tier dir.
///   • ModelScope — loose files, https://www.modelscope.ai/models/Gilgamesh-J/X-ASR-zh-en/resolve/master/&lt;path&gt;
///   • HuggingFace — loose files, https://huggingface.co/GilgameshWind/X-ASR-zh-en/resolve/main/&lt;path&gt;
/// Loose downloads stream to a .part file and rename on completion.
/// </summary>
public sealed class ModelDownloader
{
    private const string HfRepo = "GilgameshWind/X-ASR-zh-en";
    private const string MsRepo = "Gilgamesh-J/X-ASR-zh-en";
    private const string R2Host = "https://models.speech.wiki";

    private readonly ModelDownloadSource _source;
    private readonly HttpClient _http;

    public ModelDownloader(ModelDownloadSource source = ModelDownloadSource.Official, HttpClient? http = null)
    {
        _source = source;
        _http = http ?? new HttpClient { Timeout = TimeSpan.FromMinutes(30) };
        _http.DefaultRequestHeaders.UserAgent.ParseAdd("VibeXASR-Windows/2.0");
    }

    private static string RelPath(int tierMs, string file) => $"deployment/models/chunk-{tierMs}ms-model/{file}";

    private string LooseUrl(int tierMs, string file) => _source switch
    {
        ModelDownloadSource.HuggingFace => $"https://huggingface.co/{HfRepo}/resolve/main/{RelPath(tierMs, file)}",
        // Official falls back to ModelScope loose files only in the defensive per-file path (shouldn't happen).
        _ => $"https://www.modelscope.ai/models/{MsRepo}/resolve/master/{RelPath(tierMs, file)}",
    };

    private string VadUrl(string file) => $"https://huggingface.co/{HfRepo}/resolve/main/deployment/models/vad/{file}";

    /// <summary>Ensure the tier's ASR files exist locally, downloading what's missing.</summary>
    public async Task EnsureTierAsync(ModelPaths paths, IProgress<DownloadProgress>? progress = null, CancellationToken ct = default)
    {
        Directory.CreateDirectory(paths.TierDir);
        if (paths.AsrModelPresent()) return;

        if (_source == ModelDownloadSource.Official)
        {
            await DownloadTierArchiveAsync(paths, progress, ct).ConfigureAwait(false);
            return;
        }

        var jobs = new List<(string url, string dest, string name)>();
        foreach (var dest in paths.RequiredAsrFiles())
        {
            if (File.Exists(dest)) continue;
            var name = Path.GetFileName(dest);
            jobs.Add((LooseUrl(paths.TierMs, name), dest, name));
        }
        for (int i = 0; i < jobs.Count; i++)
        {
            var (url, dest, name) = jobs[i];
            await DownloadFileAsync(url, dest, name, i, jobs.Count, progress, ct).ConfigureAwait(false);
        }
    }

    /// <summary>Ensure the chosen VAD model exists (silero only — FireRed ships bundled).</summary>
    public async Task EnsureVadAsync(string destPath, IProgress<DownloadProgress>? progress = null, CancellationToken ct = default)
    {
        if (File.Exists(destPath)) return;
        Directory.CreateDirectory(Path.GetDirectoryName(destPath)!);
        var name = Path.GetFileName(destPath);
        await DownloadFileAsync(VadUrl(name), destPath, name, 0, 1, progress, ct).ConfigureAwait(false);
    }

    // ---- official CDN: archive download + extract ----

    private async Task DownloadTierArchiveAsync(ModelPaths paths, IProgress<DownloadProgress>? progress, CancellationToken ct)
    {
        var url = $"{R2Host}/asr/chunk-{paths.TierMs}ms.tar.gz";
        var tmp = Path.Combine(paths.TierDir, $"_archive-{paths.TierMs}.tar.gz.part");
        var label = $"chunk-{paths.TierMs}ms.tar.gz";

        using (var resp = await _http.GetAsync(url, HttpCompletionOption.ResponseHeadersRead, ct).ConfigureAwait(false))
        {
            resp.EnsureSuccessStatusCode();
            long? total = resp.Content.Headers.ContentLength;
            await using var src = await resp.Content.ReadAsStreamAsync(ct).ConfigureAwait(false);
            await using var dst = new FileStream(tmp, FileMode.Create, FileAccess.Write, FileShare.None, 1 << 16, useAsync: true);
            var buffer = new byte[1 << 16];
            long received = 0; int read;
            while ((read = await src.ReadAsync(buffer, ct).ConfigureAwait(false)) > 0)
            {
                await dst.WriteAsync(buffer.AsMemory(0, read), ct).ConfigureAwait(false);
                received += read;
                progress?.Report(new DownloadProgress(label, received, total, 0, 1));
            }
        }

        await ExtractTarGzAsync(tmp, paths.TierDir, ct).ConfigureAwait(false);
        try { File.Delete(tmp); } catch { }

        if (!paths.AsrModelPresent())
            throw new InvalidOperationException("archive extracted but expected model files are missing");
    }

    /// <summary>Extract a .tar.gz to <paramref name="destDir"/> (flat). Skips macOS junk (._*, .DS_Store).</summary>
    private static async Task ExtractTarGzAsync(string tarGzPath, string destDir, CancellationToken ct)
    {
        await using var fs = File.OpenRead(tarGzPath);
        await using var gz = new GZipStream(fs, CompressionMode.Decompress);
        await using var tar = new TarReader(gz);
        while (await tar.GetNextEntryAsync(copyData: false, ct).ConfigureAwait(false) is { } entry)
        {
            if (entry.EntryType is not (TarEntryType.RegularFile or TarEntryType.V7RegularFile)) continue;
            var name = Path.GetFileName(entry.Name.Replace('\\', '/').TrimEnd('/'));
            if (string.IsNullOrEmpty(name) || name.StartsWith("._") || name == ".DS_Store") continue;
            if (entry.DataStream is null) continue;
            var dest = Path.Combine(destDir, name);
            await using var outFs = new FileStream(dest, FileMode.Create, FileAccess.Write, FileShare.None, 1 << 16, useAsync: true);
            await entry.DataStream.CopyToAsync(outFs, ct).ConfigureAwait(false);
        }
    }

    // ---- loose per-file download ----

    private async Task DownloadFileAsync(string url, string dest, string name, int index, int count,
        IProgress<DownloadProgress>? progress, CancellationToken ct)
    {
        var partPath = dest + ".part";
        using var resp = await _http.GetAsync(url, HttpCompletionOption.ResponseHeadersRead, ct).ConfigureAwait(false);
        resp.EnsureSuccessStatusCode();
        long? total = resp.Content.Headers.ContentLength;
        await using (var src = await resp.Content.ReadAsStreamAsync(ct).ConfigureAwait(false))
        await using (var dst = new FileStream(partPath, FileMode.Create, FileAccess.Write, FileShare.None, 1 << 16, useAsync: true))
        {
            var buffer = new byte[1 << 16];
            long received = 0; int read;
            while ((read = await src.ReadAsync(buffer, ct).ConfigureAwait(false)) > 0)
            {
                await dst.WriteAsync(buffer.AsMemory(0, read), ct).ConfigureAwait(false);
                received += read;
                progress?.Report(new DownloadProgress(name, received, total, index, count));
            }
        }
        if (File.Exists(dest)) File.Delete(dest);
        File.Move(partPath, dest);
    }
}
