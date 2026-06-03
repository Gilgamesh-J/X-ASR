using System;
using System.Runtime.InteropServices;
using VibeXASR.Windows.Models;
using VibeXASR.Windows.Storage;
using SherpaOnnx;

namespace VibeXASR.Windows.Dictation;

/// <summary>
/// Voice-activity detector with two interchangeable backends, chosen by <see cref="VadKind"/>:
///  • <b>FireRed</b> (default, macOS parity): the native firered_vad.dll shim — Fbank + CMVN +
///    firered_vad.onnx (onnxruntime) + a speech state-machine. Emits speech segments.
///  • <b>Silero</b>: sherpa-onnx's built-in <c>VoiceActivityDetector</c> (silero_vad.onnx).
/// Both are fed 16 kHz mono float frames and expose "is there speech now" + drained segments.
/// If FireRed fails to initialize (DLL/model missing) it falls back to Silero so the engine
/// still starts.
/// </summary>
public sealed class Vad : IDisposable
{
    private readonly IVadBackend _backend;

    /// <summary>The backend actually in use (FireRed may fall back to Silero).</summary>
    public VadKind Active { get; }

    public Vad(ModelPaths paths, VadKind kind, int sampleRate = 16000)
    {
        if (kind == VadKind.FireRed)
        {
            try
            {
                _backend = new FireRedBackend(paths.FireRedDir, sampleRate);
                Active = VadKind.FireRed;
                Diag.Log("VAD: FireRed (native shim)");
                return;
            }
            catch (Exception ex)
            {
                Diag.Log("VAD: FireRed init failed → falling back to Silero — " + ex.Message);
            }
        }
        _backend = new SileroBackend(paths, sampleRate);
        Active = VadKind.Silero;
        Diag.Log("VAD: Silero (sherpa-onnx)");
    }

    public void AcceptWaveform(float[] samples) => _backend.AcceptWaveform(samples);
    public bool IsSpeechDetected() => _backend.IsSpeechDetected();
    public bool HasSegment() => _backend.HasSegment();
    public float[]? PopSegment() => _backend.PopSegment();
    public void Flush() => _backend.Flush();
    public void Reset() => _backend.Reset();
    public void Dispose() => _backend.Dispose();
}

internal interface IVadBackend : IDisposable
{
    void AcceptWaveform(float[] samples);
    bool IsSpeechDetected();
    bool HasSegment();
    float[]? PopSegment();
    void Flush();
    void Reset();
}

/// <summary>sherpa-onnx Silero VAD backend (the original implementation).</summary>
internal sealed class SileroBackend : IVadBackend
{
    private readonly VoiceActivityDetector _vad;

    public SileroBackend(ModelPaths paths, int sampleRate)
    {
        var vadPath = paths.SileroVad;
        if (!System.IO.File.Exists(vadPath))
            throw new InvalidOperationException($"Silero VAD model missing: {vadPath}");

        var config = new VadModelConfig();
        config.SileroVad.Model = vadPath;
        config.SileroVad.Threshold = 0.5f;
        config.SileroVad.MinSilenceDuration = 0.25f;
        config.SileroVad.MinSpeechDuration = 0.10f;
        config.SileroVad.WindowSize = 512;
        config.SampleRate = sampleRate;
        config.NumThreads = 1;
        config.Provider = "cpu";
        _vad = new VoiceActivityDetector(config, bufferSizeInSeconds: 30f);
    }

    public void AcceptWaveform(float[] samples) => _vad.AcceptWaveform(samples);
    public bool IsSpeechDetected() => _vad.IsSpeechDetected();
    public bool HasSegment() => !_vad.IsEmpty();
    public float[]? PopSegment()
    {
        if (_vad.IsEmpty()) return null;
        var seg = _vad.Front();
        _vad.Pop();
        return seg.Samples;
    }
    public void Flush() => _vad.Flush();
    public void Reset() => _vad.Reset();
    public void Dispose() => _vad?.Dispose();
}

/// <summary>
/// FireRedVAD backend over the native firered_vad.dll (the Windows port of the macOS CFireRed
/// shim). Feeds int16 PCM; the shim runs Fbank+CMVN+ONNX+state-machine and emits speech segments.
/// In OnCall the engine uses this purely as a speech on/off + "a segment completed" signal — the
/// segment audio is fed to the ASR separately — so <see cref="PopSegment"/> returns no samples.
/// </summary>
internal sealed class FireRedBackend : IVadBackend
{
    private const string Dll = "firered_vad";
    private IntPtr _h;
    private int _pending;   // completed segments drained from the shim, awaiting Pop

    public FireRedBackend(string modelDir, int sampleRate)
    {
        NativeLoader.EnsureRegistered();
        _h = frv_create(modelDir);
        if (_h == IntPtr.Zero)
            throw new InvalidOperationException($"frv_create failed for model dir: {modelDir}");
    }

    public void AcceptWaveform(float[] samples)
    {
        if (_h == IntPtr.Zero || samples.Length == 0) return;
        var i16 = new short[samples.Length];
        for (int i = 0; i < samples.Length; i++)
        {
            int v = (int)(samples[i] * 32767f);
            i16[i] = (short)Math.Clamp(v, -32768, 32767);
        }
        frv_accept_int16(_h, i16, i16.Length);
        DrainSegments();
    }

    public bool IsSpeechDetected() => _h != IntPtr.Zero && frv_is_speech(_h) != 0;
    public bool HasSegment() => _pending > 0;
    public float[]? PopSegment() { if (_pending > 0) _pending--; return Array.Empty<float>(); }

    public void Flush()
    {
        if (_h == IntPtr.Zero) return;
        frv_flush(_h);
        DrainSegments();
    }

    public void Reset()
    {
        if (_h == IntPtr.Zero) return;
        frv_reset(_h);
        _pending = 0;
    }

    private void DrainSegments()
    {
        while (frv_poll_segment(_h, out _, out _) != 0) _pending++;
    }

    public void Dispose()
    {
        if (_h != IntPtr.Zero) { frv_free(_h); _h = IntPtr.Zero; }
    }

    // ---- firered_vad.dll C API (all default/cdecl; x64 conventions are uniform) ----
    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl, CharSet = CharSet.Ansi)]
    private static extern IntPtr frv_create(string modelDir);
    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
    private static extern void frv_accept_int16(IntPtr v, short[] samples, int n);
    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
    private static extern int frv_is_speech(IntPtr v);
    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
    private static extern int frv_poll_segment(IntPtr v, out double startS, out double endS);
    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
    private static extern void frv_flush(IntPtr v);
    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
    private static extern void frv_reset(IntPtr v);
    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
    private static extern void frv_free(IntPtr v);
}
