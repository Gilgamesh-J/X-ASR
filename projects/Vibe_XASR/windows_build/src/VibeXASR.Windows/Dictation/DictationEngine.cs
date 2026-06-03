using System;
using System.Collections.Generic;
using System.IO;
using System.Threading;
using VibeXASR.Windows.Lexicon;
using VibeXASR.Windows.Models;
using VibeXASR.Windows.Storage;

namespace VibeXASR.Windows.Dictation;

/// <summary>Fired as the hypothesis grows. Text is the full current partial (de-spaced).</summary>
public sealed class PartialEventArgs(string text) : EventArgs
{
    public string Text { get; } = text;
}

/// <summary>Fired when an utterance/segment finalizes.</summary>
public sealed class FinalEventArgs(string text) : EventArgs
{
    public string Text { get; } = text;
}

/// <summary>
/// Orchestrates mic frames -> VAD -> streaming ASR, implementing the three dictation
/// modes and a faithful port of the macOS engine's edge-endpointing:
///
///  - PREROLL: keep a short rolling buffer of audio BEFORE speech is detected, so the
///    first phoneme isn't clipped. On speech onset we replay the preroll into the ASR.
///  - WINDOWING: frames flow continuously to the ASR while speech is active.
///  - ENDPOINTING: a segment ends when the VAD reports trailing silence (or, in
///    Paste/Type, when the hotkey is released). On end we Finalize() and raise OnFinal.
///
/// Threading: a single worker thread owns the ASR/VAD (sherpa streams are not thread-safe).
/// Mic frames are posted into a queue; everything else happens on the worker.
/// </summary>
public sealed class DictationEngine : IDisposable
{
    private const int SampleRate = 16000;

    // Preroll length: ~300 ms of audio retained ahead of detected speech.
    private const int PrerollMs = 300;
    private const int PrerollSamples = SampleRate * PrerollMs / 1000;

    private readonly Settings _settings;
    private readonly ModelPaths _paths;

    private StreamingAsr? _asr;
    private Vad? _vad;

    // mic frame queue
    private readonly System.Collections.Concurrent.BlockingCollection<float[]> _frames = new();
    private Thread? _worker;
    private volatile bool _running;

    // rolling preroll ring (worker-thread only)
    private readonly Queue<float> _preroll = new(PrerollSamples + 4096);

    // In Paste/Type the hotkey gates capture; in OnCall capture is always live.
    private volatile bool _capturing;
    private volatile bool _speechActive;

    private DictationMode _mode;
    /// <summary>
    /// Current mode. Setting it updates continuous-capture state: OnCall captures
    /// immediately; Paste/Type fall back to hotkey gating (and finalize any in-flight
    /// utterance when leaving OnCall).
    /// </summary>
    public DictationMode Mode
    {
        get => _mode;
        set
        {
            bool leavingOnCall = _mode == DictationMode.OnCall && value != DictationMode.OnCall;
            _mode = value;
            _capturing = value == DictationMode.OnCall;
            if (leavingOnCall) _flushRequested = true;
        }
    }

    private bool _paused;
    /// <summary>Pause OnCall capture without leaving the mode (the overlay Pause button).
    /// Pausing finalizes the in-flight utterance so the last segment isn't lost (macOS
    /// fix(oncall): "停止/暂停时确定 in-flight partial,不再丢失最后一段").</summary>
    public bool Paused
    {
        get => _paused;
        set
        {
            if (value && !_paused) _flushRequested = true; // commit in-flight before pausing
            _paused = value;
        }
    }

    public event EventHandler<PartialEventArgs>? OnPartial;
    public event EventHandler<FinalEventArgs>? OnFinal;

    public DictationEngine(Settings settings)
    {
        _settings = settings;
        _paths = ModelPaths.ForTier(settings.Tier);
        Mode = settings.Mode;
    }

    /// <summary>
    /// Load models and start the worker thread. Throws if model files are missing
    /// (caller should run ModelDownloader first). Idempotent.
    /// </summary>
    public void Start()
    {
        if (_running) return;

        // Hotwords (词典): write/remove the file from settings + resolve the bundled bpe.vocab.
        string? hwFile = null, bpe = null;
        var hwPath = _paths.HotwordsFile;
        if (_settings.HotwordsEnabled && HotwordsStore.WriteFile(_settings.HotwordsText, _settings.HotwordsScore, hwPath))
        {
            hwFile = hwPath;
            if (File.Exists(_paths.BpeVocab)) bpe = _paths.BpeVocab;
        }
        else { try { if (File.Exists(hwPath)) File.Delete(hwPath); } catch { /* best-effort */ } }
        _asr = new StreamingAsr(_paths, SampleRate, hwFile, (float)_settings.HotwordsScore, bpe);
        _vad = new Vad(_paths, _paths.ResolveVad(_settings.Vad), SampleRate);

        _running = true;
        _worker = new Thread(WorkerLoop) { IsBackground = true, Name = "VibeXASR-DictationWorker" };
        _worker.Start();

        // OnCall captures continuously; Paste/Type wait for the hotkey.
        _capturing = Mode == DictationMode.OnCall;
    }

    /// <summary>
    /// Push a mic frame (16 kHz mono float). Cheap & non-blocking; the worker consumes it.
    /// Call this from MicCapture's callback.
    /// </summary>
    public void PushFrame(float[] frame)
    {
        if (_running) _frames.Add(frame);
    }

    // ---- hotkey gating (Paste / Type) ----

    /// <summary>Hotkey pressed: begin capturing for push-to-talk modes.</summary>
    public void BeginHold()
    {
        if (Mode == DictationMode.OnCall) return; // always on
        _capturing = true;
    }

    /// <summary>
    /// Hotkey released: stop capturing and force-finalize the in-flight utterance.
    /// </summary>
    public void EndHold()
    {
        if (Mode == DictationMode.OnCall) return;
        _capturing = false;
        // Signal the worker to flush + finalize. Use a sentinel empty frame? Simpler:
        // set a flag the worker checks. We piggy-back on _capturing == false below.
        _flushRequested = true;
    }

    private volatile bool _flushRequested;

    // ---- worker ----

    private void WorkerLoop()
    {
        string lastEmittedPartial = string.Empty;

        while (_running)
        {
            float[]? frame;
            try
            {
                // Wake periodically so we can honour _flushRequested even when no audio arrives.
                if (!_frames.TryTake(out frame, millisecondsTimeout: 50))
                    frame = null;
            }
            catch (InvalidOperationException)
            {
                break; // collection completed
            }

            // Maintain preroll ring regardless of capture state, so onset isn't clipped.
            if (frame is not null) PushPreroll(frame);

            bool capturing = _capturing && !Paused;
            bool ptt = Mode != DictationMode.OnCall;

            if (capturing && frame is not null)
            {
                if (ptt)
                {
                    // PUSH-TO-TALK: the user is deliberately holding the key, so stream the
                    // WHOLE hold to the ASR. Do NOT gate on the VAD — a quiet mic or a finicky
                    // VAD threshold must never swallow the speech (that produced "no text").
                    if (!_speechActive)
                    {
                        _speechActive = true;
                        var pre = DrainPreroll();
                        if (pre.Length > 0) _asr!.AcceptWaveform(pre);
                        Diag.Log($"engine: PTT capture start (preroll {pre.Length} samples)");
                    }
                    _asr!.AcceptWaveform(frame);
                    var partial = _asr.Partial();
                    if (partial != lastEmittedPartial)
                    {
                        lastEmittedPartial = partial;
                        OnPartial?.Invoke(this, new PartialEventArgs(partial));
                    }
                }
                else
                {
                    // ON-CALL: always-on, so VAD segments utterances.
                    _vad!.AcceptWaveform(frame);
                    bool nowSpeech = _vad.IsSpeechDetected();
                    if (nowSpeech && !_speechActive)
                    {
                        _speechActive = true;
                        var pre = DrainPreroll();
                        if (pre.Length > 0) _asr!.AcceptWaveform(pre);
                    }
                    if (_speechActive)
                    {
                        _asr!.AcceptWaveform(frame);
                        var partial = _asr.Partial();
                        if (partial != lastEmittedPartial)
                        {
                            lastEmittedPartial = partial;
                            OnPartial?.Invoke(this, new PartialEventArgs(partial));
                        }
                        if ((!nowSpeech && _vad.HasSegment()) || _asr.IsEndpoint())
                            FinalizeUtterance(ref lastEmittedPartial);
                    }
                }
            }

            // Hotkey released (Paste/Type): finalize the hold and ALWAYS signal end-of-hold so
            // the UI can drop the overlay even when nothing was recognized.
            if (_flushRequested)
            {
                _flushRequested = false;
                try { _vad!.Flush(); } catch { /* vad may be mid-state */ }
                FinalizeUtterance(ref lastEmittedPartial, endOfHold: true);
                _speechActive = false;
            }
        }
    }

    private void FinalizeUtterance(ref string lastEmittedPartial, bool endOfHold = false)
    {
        var text = _asr!.Finalize();
        _speechActive = false;
        lastEmittedPartial = string.Empty;
        // Drain any completed VAD segments so they don't leak into the next utterance.
        while (_vad!.HasSegment()) _vad.PopSegment();

        Diag.Log($"engine: finalize len={text?.Length ?? 0} endOfHold={endOfHold} text=\"{(text ?? "")}\"");
        if (!string.IsNullOrWhiteSpace(text))
            OnFinal?.Invoke(this, new FinalEventArgs(text));
        else if (endOfHold)
            // Nothing recognized — fire an empty final so the host can close the overlay.
            OnFinal?.Invoke(this, new FinalEventArgs(string.Empty));
    }

    // ---- preroll ring helpers ----

    private void PushPreroll(float[] frame)
    {
        foreach (var s in frame) _preroll.Enqueue(s);
        while (_preroll.Count > PrerollSamples) _preroll.Dequeue();
    }

    private float[] DrainPreroll()
    {
        var arr = _preroll.ToArray();
        _preroll.Clear();
        return arr;
    }

    public void Dispose()
    {
        _running = false;
        _frames.CompleteAdding();
        _worker?.Join(1000);
        _asr?.Dispose();
        _vad?.Dispose();
        _frames.Dispose();
    }
}
