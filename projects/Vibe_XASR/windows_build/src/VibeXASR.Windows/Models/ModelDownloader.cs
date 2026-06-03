using System;
using System.Collections.Generic;
using System.IO;
using System.Net.Http;
using System.Threading;
using System.Threading.Tasks;

namespace VibeXASR.Windows.Models;

/// <summary>Progress callback payload for a single file download.</summary>
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
/// Downloads the per-tier streaming model files from HuggingFace:
///   https://huggingface.co/GilgameshWind/X-ASR-zh-en/resolve/main/deployment/models/chunk-&lt;T&gt;ms-model/&lt;file&gt;
/// Files are streamed to disk with progress; partial downloads use a .part suffix
/// and are renamed on completion so an interrupted fetch never leaves a half file
/// that looks valid.
/// </summary>
public sealed class ModelDownloader
{
    private const string Repo = "GilgameshWind/X-ASR-zh-en";

    // resolve/main/... returns the raw file (follows LFS redirects).
    private static string TierFileUrl(int tierMs, string file) =>
        $"https://huggingface.co/{Repo}/resolve/main/deployment/models/chunk-{tierMs}ms-model/{file}";

    // TODO(win): confirm the exact VAD asset paths in the HF repo. The macOS app
    // ships silero_vad.onnx / fireredvad.onnx; adjust these once verified.
    private static string VadFileUrl(string file) =>
        $"https://huggingface.co/{Repo}/resolve/main/deployment/models/vad/{file}";

    private readonly HttpClient _http;

    public ModelDownloader(HttpClient? http = null)
    {
        _http = http ?? new HttpClient
        {
            Timeout = TimeSpan.FromMinutes(30), // model files can be large.
        };
        // TODO(win): set a User-Agent; some HF endpoints reject empty UAs.
        _http.DefaultRequestHeaders.UserAgent.ParseAdd("VibeXASR-Windows/0.1");
    }

    /// <summary>
    /// Ensure the four ASR files for <paramref name="paths"/> exist locally,
    /// downloading any that are missing. Safe to call repeatedly.
    /// </summary>
    public async Task EnsureTierAsync(
        ModelPaths paths,
        IProgress<DownloadProgress>? progress = null,
        CancellationToken ct = default)
    {
        Directory.CreateDirectory(paths.TierDir);

        // file name -> destination path
        var jobs = new List<(string url, string dest, string name)>();
        foreach (var dest in paths.RequiredAsrFiles())
        {
            if (File.Exists(dest)) continue;
            var name = Path.GetFileName(dest);
            jobs.Add((TierFileUrl(paths.TierMs, name), dest, name));
        }

        for (int i = 0; i < jobs.Count; i++)
        {
            var (url, dest, name) = jobs[i];
            await DownloadFileAsync(url, dest, name, i, jobs.Count, progress, ct)
                .ConfigureAwait(false);
        }
    }

    /// <summary>Ensure the chosen VAD model exists, downloading if missing.</summary>
    public async Task EnsureVadAsync(
        string destPath,
        IProgress<DownloadProgress>? progress = null,
        CancellationToken ct = default)
    {
        if (File.Exists(destPath)) return;
        Directory.CreateDirectory(Path.GetDirectoryName(destPath)!);
        var name = Path.GetFileName(destPath);
        await DownloadFileAsync(VadFileUrl(name), destPath, name, 0, 1, progress, ct)
            .ConfigureAwait(false);
    }

    private async Task DownloadFileAsync(
        string url,
        string dest,
        string name,
        int index,
        int count,
        IProgress<DownloadProgress>? progress,
        CancellationToken ct)
    {
        var partPath = dest + ".part";

        using var resp = await _http
            .GetAsync(url, HttpCompletionOption.ResponseHeadersRead, ct)
            .ConfigureAwait(false);
        resp.EnsureSuccessStatusCode();

        long? total = resp.Content.Headers.ContentLength;

        await using (var src = await resp.Content.ReadAsStreamAsync(ct).ConfigureAwait(false))
        await using (var dst = new FileStream(partPath, FileMode.Create, FileAccess.Write,
                         FileShare.None, bufferSize: 1 << 16, useAsync: true))
        {
            var buffer = new byte[1 << 16];
            long received = 0;
            int read;
            while ((read = await src.ReadAsync(buffer, ct).ConfigureAwait(false)) > 0)
            {
                await dst.WriteAsync(buffer.AsMemory(0, read), ct).ConfigureAwait(false);
                received += read;
                progress?.Report(new DownloadProgress(name, received, total, index, count));
            }
        }

        // Atomic-ish swap into place.
        if (File.Exists(dest)) File.Delete(dest);
        File.Move(partPath, dest);
    }
}
