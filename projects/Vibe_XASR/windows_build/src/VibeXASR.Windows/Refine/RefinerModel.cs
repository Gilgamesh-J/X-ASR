using System;
using System.Collections.Generic;
using System.IO;
using System.Net.Http;
using System.Threading;
using System.Threading.Tasks;
using VibeXASR.Windows.Models;     // DownloadProgress
using VibeXASR.Windows.Storage;    // AppPaths

namespace VibeXASR.Windows.Refine;

/// <summary>
/// On-disk location + on-demand download of the AI 润色(本地)GGUF — the CPM5 refiner model.
/// Port of macOS ModelPaths.refiner* + ModelDownloader's refiner bits.
///
/// The model is NOT bundled in the MSI (~656 MB). It downloads on demand to
/// <c>%APPDATA%\VibeXASR\models\refiner\</c>, with the same source order macOS uses:
///   ① 官方加速线路 (Cloudflare R2)  ② ModelScope 作者仓库 (CPM5_refiner_v1).
/// A bundled copy under <c>&lt;app dir&gt;\models\refiner\</c> (if a future build ships one) wins for reads,
/// mirroring the macOS "bundled internal-test build" path.
/// </summary>
internal static class RefinerModel
{
    /// <summary>Current refiner GGUF file name (CPM5_refiner_v1, q4_k_m). Renaming forces a re-download
    /// when the model is swapped (old caches are then orphaned) — matches macOS refinerFileName.</summary>
    public const string FileName = "refiner-cpm5-q4_k_m.gguf";

    /// <summary>Approx download size (bytes), for the UI hint. The R2 object is 688,065,920 B ≈ 656 MB.</summary>
    public const long ExpectedBytes = 688_065_920L;

    /// <summary>Download target dir (writable): %APPDATA%\VibeXASR\models\refiner.</summary>
    public static string Dir => Path.Combine(AppPaths.DataDir, "models", "refiner");

    /// <summary>Writable cache path (download target).</summary>
    public static string CachePath => Path.Combine(Dir, FileName);

    /// <summary>Optional bundled copy beside the exe (read-only) — not shipped today, but honored if present.</summary>
    public static string BundledPath => Path.Combine(AppContext.BaseDirectory, "models", "refiner", FileName);

    /// <summary>The path to load from: prefer the writable cache, else a bundled copy.</summary>
    public static string ResolvedPath => File.Exists(CachePath) ? CachePath : BundledPath;

    /// <summary>Is the GGUF downloaded + plausibly complete? (size guard rejects truncated leftovers).</summary>
    public static bool Available()
    {
        foreach (var p in new[] { CachePath, BundledPath })
            try { if (File.Exists(p) && new FileInfo(p).Length > 200_000_000L) return true; } catch { }
        return false;
    }

    /// <summary>Download sources, tried in order (UI shows no per-source detail — silent fallback):
    /// ① 官方加速线路 (R2 CDN) ② ModelScope 作者仓库 (needs the same-named GGUF uploaded there to hit).</summary>
    public static IReadOnlyList<string> Candidates() => new[]
    {
        $"https://models.speech.wiki/refiner/{FileName}",
        $"https://www.modelscope.cn/models/MuyuanJ/CPM5_refiner_v1/resolve/master/{FileName}",
    };

    /// <summary>Download the GGUF (if not already present), trying each source until one succeeds. Streams to a
    /// .part file and renames on completion so a cancelled/failed download never leaves a "present" partial.
    /// Returns true once the model is available. Throws only if EVERY source failed.</summary>
    public static async Task<bool> DownloadAsync(IProgress<DownloadProgress>? progress = null, CancellationToken ct = default)
    {
        if (Available()) return true;
        Directory.CreateDirectory(Dir);
        var dest = CachePath;
        var part = dest + ".part";

        using var http = new HttpClient { Timeout = TimeSpan.FromMinutes(60) };
        http.DefaultRequestHeaders.UserAgent.ParseAdd("VibeXASR-Windows/2.0");

        Exception? last = null;
        foreach (var url in Candidates())
        {
            ct.ThrowIfCancellationRequested();
            try
            {
                using var resp = await http.GetAsync(url, HttpCompletionOption.ResponseHeadersRead, ct).ConfigureAwait(false);
                resp.EnsureSuccessStatusCode();
                long? total = resp.Content.Headers.ContentLength ?? ExpectedBytes;
                await using (var src = await resp.Content.ReadAsStreamAsync(ct).ConfigureAwait(false))
                await using (var dst = new FileStream(part, FileMode.Create, FileAccess.Write, FileShare.None, 1 << 16, useAsync: true))
                {
                    var buffer = new byte[1 << 16];
                    long received = 0; int read;
                    while ((read = await src.ReadAsync(buffer, ct).ConfigureAwait(false)) > 0)
                    {
                        await dst.WriteAsync(buffer.AsMemory(0, read), ct).ConfigureAwait(false);
                        received += read;
                        progress?.Report(new DownloadProgress(FileName, received, total, 0, 1));
                    }
                }
                if (File.Exists(dest)) File.Delete(dest);
                File.Move(part, dest);
                Diag.Log($"RefinerModel: downloaded {FileName} from {url}");
                // The CDN GGUF tags tokenizer.ggml.pre="minicpm5", which LLamaSharp's llama.cpp can't load.
                // Rewrite it to "qwen2" (identical regex bar digit grouping) so the model loads on Windows.
                GgufPatcher.EnsureWindowsCompatible(dest);
                return true;
            }
            catch (OperationCanceledException) { TryDeletePart(part); throw; }
            catch (Exception ex)
            {
                last = ex;
                Diag.Log($"RefinerModel: source failed ({url}): {ex.Message}");
                TryDeletePart(part);
            }
        }
        throw last ?? new InvalidOperationException("refiner download: no sources");
    }

    /// <summary>Delete the downloaded GGUF (frees ~656 MB). Best-effort.</summary>
    public static void Delete()
    {
        foreach (var p in new[] { CachePath, CachePath + ".part" })
            try { if (File.Exists(p)) File.Delete(p); } catch { }
    }

    private static void TryDeletePart(string part) { try { if (File.Exists(part)) File.Delete(part); } catch { } }
}
