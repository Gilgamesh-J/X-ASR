using System;
using System.Collections.Concurrent;
using System.Threading;
using System.Threading.Tasks;
using VibeXASR.Windows.Storage;

namespace VibeXASR.Windows.Models;

/// <summary>
/// Tracks per-tier model download state (progress / failed) on top of
/// <see cref="ModelDownloader"/>, so the Settings "Model management" list can show
/// live progress, Use / Download / Cancel / Delete — mirroring the macOS
/// ModelDownloader bridge. Thread-safe; the UI polls the getters on a timer.
/// </summary>
public sealed class ModelManager
{
    private readonly Settings _settings;
    private readonly ConcurrentDictionary<int, double> _progress = new(); // tier -> 0..1 (present only while downloading)
    private readonly ConcurrentDictionary<int, bool> _failed = new();
    private readonly ConcurrentDictionary<int, CancellationTokenSource> _cts = new();

    /// <summary>Raised (on a thread-pool thread) whenever download state changes.</summary>
    public event Action? Changed;

    public ModelManager(Settings settings) => _settings = settings;

    public bool IsTierDownloaded(ModelTier tier) => ModelPaths.ForTier(tier).AsrModelPresent();
    public bool IsDownloading(ModelTier tier) => _progress.ContainsKey((int)tier);
    public double? DownloadProgress(ModelTier tier)
        => _progress.TryGetValue((int)tier, out var p) ? p : null;
    public bool DidTierFail(ModelTier tier) => _failed.TryGetValue((int)tier, out var f) && f;

    /// <summary>Begin (or retry) downloading a tier + the active VAD. No-op if already running.</summary>
    public void StartDownload(ModelTier tier)
    {
        int key = (int)tier;
        if (_progress.ContainsKey(key)) return;
        _failed[key] = false;
        _progress[key] = 0.0;
        var cts = new CancellationTokenSource();
        _cts[key] = cts;
        Changed?.Invoke();

        _ = Task.Run(async () =>
        {
            try
            {
                var paths = ModelPaths.ForTier(tier);
                var dl = new ModelDownloader(ModelSourceX.From(_settings.ModelSource));
                var progress = new Progress<DownloadProgress>(p =>
                {
                    if (p.Fraction is { } f) { _progress[key] = f; Changed?.Invoke(); }
                });
                await dl.EnsureTierAsync(paths, progress, cts.Token).ConfigureAwait(false);
                await dl.EnsureVadAsync(paths.VadFileFor(_settings.EffectiveVad), progress, cts.Token)
                        .ConfigureAwait(false);
            }
            catch (OperationCanceledException) { /* user cancelled */ }
            catch { _failed[key] = true; }
            finally
            {
                _progress.TryRemove(key, out _);
                _cts.TryRemove(key, out _);
                Changed?.Invoke();
            }
        });
    }

    public void CancelDownload(ModelTier tier)
    {
        if (_cts.TryGetValue((int)tier, out var cts)) cts.Cancel();
    }

    /// <summary>Delete a tier's downloaded files (frees ~615 MB). Returns true if removed.</summary>
    public bool DeleteTier(ModelTier tier)
    {
        try
        {
            var dir = ModelPaths.ForTier(tier).TierDir;
            if (System.IO.Directory.Exists(dir))
            {
                System.IO.Directory.Delete(dir, recursive: true);
                Changed?.Invoke();
                return true;
            }
        }
        catch { /* in use / locked */ }
        return false;
    }
}
