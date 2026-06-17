using System;
using System.Collections.Generic;
using System.IO;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using LLama;
using LLama.Common;
using LLama.Native;
using LLama.Sampling;

namespace VibeXASR.Windows.Refine;

/// <summary>
/// Local llama.cpp backend for AI 润色(Beta)— the offline equivalent of the cloud refiner.
/// Faithful port of macOS LlamaRefiner.swift, on LLamaSharp (CPU backend).
///
/// Loads the CPM5 refiner GGUF (MiniCPM5-1B, q4_k_m) and runs one greedy (temperature 0) pass over the
/// whole utterance. macOS uses Metal (n_gpu_layers=999); on Windows we run CPU-only (GpuLayerCount=0) —
/// universal, no GPU/driver requirement; a 1B q4 model on a short utterance is ≈ 1–3 s.
///
/// Threading: <see cref="StatelessExecutor"/> creates a fresh context per <c>InferAsync</c> (matching the
/// macOS "new context per segment" design, so no cross-utterance KV residue). A <see cref="SemaphoreSlim"/>
/// serialises calls so overlapping dictations can't touch the model concurrently.
///
/// Loading is async + lazy: construction is cheap; <see cref="LoadAsync"/> does the heavy ~656 MB load on a
/// background thread and flips <see cref="IsReady"/> when done. Until then the facade sees IsReady=false and
/// returns the input untouched (never waits) — the macOS "not ready → return input" contract.
/// </summary>
internal sealed class LocalRefiner : IRefinerBackend, IDisposable
{
    private readonly string _modelPath;
    private readonly int _threads;
    private readonly int _maxNewTokens;
    private readonly SemaphoreSlim _gate = new(1, 1);

    private LLamaWeights? _weights;
    private ModelParams? _params;
    private StatelessExecutor? _executor;
    private volatile bool _ready;
    private volatile bool _loadFailed;

    public LocalRefiner(string modelPath, int threads = 4, int maxNewTokens = 512)
    {
        _modelPath = modelPath;
        _threads = threads;
        _maxNewTokens = maxNewTokens;
    }

    public bool IsReady => _ready;
    public bool LoadFailed => _loadFailed;

    /// <summary>CPM5 is trained to append an "uncertain words" tail (`…&lt;KEY&gt;[词1、词2]`); the facade strips it
    /// and relaxes the guardrails (CPM5 does its own ITN/改口). See Refiner.PolishAsync.</summary>
    public bool EmitsUncertainList => true;

    /// <summary>Tell LLamaSharp where to find the loose native llama/ggml DLLs. In a single-file publish the
    /// `runtimes\&lt;rid&gt;\native\&lt;avx&gt;\` tree sits next to the .exe (AppContext.BaseDirectory); add it to the
    /// search path so auto-detection finds the right AVX variant. Idempotent; must run before the first load.</summary>
    private static int _nativeConfigured;
    internal static void ConfigureNativeOnce()
    {
        if (Interlocked.Exchange(ref _nativeConfigured, 1) != 0) return;
        try
        {
            NativeLibraryConfig.All.WithSearchDirectory(AppContext.BaseDirectory)
                // Only surface warnings/errors — the per-tensor load chatter would bloat users' logs.
                .WithLogCallback((level, msg) =>
                {
                    if ((level == LLamaLogLevel.Warning || level == LLamaLogLevel.Error) && !string.IsNullOrWhiteSpace(msg))
                        Diag.Log("[llama] " + msg.TrimEnd());
                });
        }
        catch (Exception ex) { Diag.Log("LocalRefiner.ConfigureNativeOnce: " + ex.Message); }
    }

    /// <summary>Load the GGUF on a background thread. Safe to call once; sets IsReady on success, LoadFailed on
    /// error (facade then stays in safe no-op). The model file must already exist (downloaded).</summary>
    public Task LoadAsync() => Task.Run(() =>
    {
        if (_ready || _loadFailed) return;
        if (!File.Exists(_modelPath)) { _loadFailed = true; Diag.Log("LocalRefiner: model missing " + _modelPath); return; }
        try
        {
            GgufPatcher.EnsureWindowsCompatible(_modelPath);   // cheap no-op if already qwen2; fixes an unpatched leftover
            ConfigureNativeOnce();
            var mp = new ModelParams(_modelPath)
            {
                ContextSize = 2048,
                GpuLayerCount = 0,                 // CPU only (universal); macOS uses Metal=999
                Threads = _threads,
            };
            var sw = System.Diagnostics.Stopwatch.StartNew();
            _weights = LLamaWeights.LoadFromFile(mp);
            _params = mp;
            _executor = new StatelessExecutor(_weights, mp);
            _ready = true;
            Diag.Log($"LocalRefiner: loaded {Path.GetFileName(_modelPath)} in {sw.ElapsedMilliseconds} ms (CPU, ctx 2048)");
        }
        catch (Exception ex)
        {
            _loadFailed = true;
            Diag.Log("LocalRefiner: load failed — " + ex.Message);
            Dispose();
        }
    });

    // MARK: IRefinerBackend

    public async Task<string?> RefineAsync(string system, string text, CancellationToken ct)
    {
        var exec = _executor;
        if (!_ready || exec is null) return null;
        var prompt = BuildPrompt(system, text);

        await _gate.WaitAsync(ct).ConfigureAwait(false);
        try
        {
            var ip = new InferenceParams
            {
                MaxTokens = _maxNewTokens,
                // CPM5 uses the Qwen3/ChatML template; <|im_end|> is an EOG token so generation also stops
                // natively, but the anti-prompts are a harmless belt-and-suspenders stop.
                AntiPrompts = new List<string> { "<|im_end|>", "<|endoftext|>" },
                SamplingPipeline = new GreedySamplingPipeline(),   // temperature 0 — deterministic, reproducible
            };
            var sb = new StringBuilder();
            // LLamaSharp accumulates UTF-8 bytes across tokens internally (CJK spans multiple tokens), so the
            // streamed strings are already valid text — no manual byte-buffer like the macOS C-API path.
            await foreach (var piece in exec.InferAsync(prompt, ip, ct).ConfigureAwait(false))
                sb.Append(piece);
            var outp = sb.ToString().Trim();
            return outp.Length == 0 ? null : outp;
        }
        catch (OperationCanceledException) { return null; }
        catch (Exception ex) { Diag.Log("LocalRefiner.RefineAsync: " + ex.Message); return null; }
        finally { _gate.Release(); }
    }

    // MARK: helpers

    /// <summary>Build the Qwen3 / ChatML prompt (system + user). The CPM5 GGUF carries the Qwen3 chat template;
    /// macOS applies it via llama_chat_apply_template(nil,…). LLamaSharp's StatelessExecutor takes a raw prompt
    /// string, so we render ChatML directly (deterministic, no dependency on the model's embedded template).</summary>
    private static string BuildPrompt(string system, string user)
    {
        var sb = new StringBuilder();
        if (!string.IsNullOrEmpty(system))
            sb.Append("<|im_start|>system\n").Append(system).Append("<|im_end|>\n");
        sb.Append("<|im_start|>user\n").Append(user).Append("<|im_end|>\n");
        sb.Append("<|im_start|>assistant\n");
        return sb.ToString();
    }

    public void Dispose()
    {
        try { _weights?.Dispose(); } catch { }
        _weights = null;
        _executor = null;
        _ready = false;
    }
}
