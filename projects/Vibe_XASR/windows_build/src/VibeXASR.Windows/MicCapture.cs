using System;
using NAudio.CoreAudioApi;
using NAudio.Wave;
using NAudio.Wave.SampleProviders;

namespace VibeXASR.Windows;

/// <summary>
/// Captures the default microphone via WASAPI (shared mode) and delivers 16 kHz mono
/// float frames to <see cref="FrameAvailable"/>. NAudio gives us device-native format
/// (often 44.1/48 kHz, stereo); we down-mix to mono and resample to 16 kHz.
/// </summary>
public sealed class MicCapture : IDisposable
{
    private const int TargetRate = 16000;

    private WasapiCapture? _capture;
    private BufferedWaveProvider? _buffer;
    private ISampleProvider? _resampledMono;

    /// <summary>Capture from this endpoint ID. Empty/unknown => system default recording device.</summary>
    public string? DeviceId { get; set; }

    public MicCapture(string? deviceId = null) => DeviceId = deviceId;

    /// <summary>Raised with a 16 kHz mono float frame (length depends on capture buffer).</summary>
    public event EventHandler<float[]>? FrameAvailable;

    public bool IsRunning { get; private set; }

    /// <summary>All active capture (microphone) endpoints: (id, friendly name).</summary>
    public static System.Collections.Generic.List<(string Id, string Name)> Devices()
    {
        var list = new System.Collections.Generic.List<(string, string)>();
        try
        {
            using var en = new MMDeviceEnumerator();
            foreach (var d in en.EnumerateAudioEndPoints(DataFlow.Capture, DeviceState.Active))
            {
                try { list.Add((d.ID, d.FriendlyName)); } finally { d.Dispose(); }
            }
        }
        catch { /* enumeration unavailable */ }
        return list;
    }

    public void Start()
    {
        if (IsRunning) return;

        // Resolve the chosen device by ID; otherwise the user's DEFAULT recording device
        // (Role.Console = Windows "Default Device"). NOT Role.Communications — that's the
        // separate "Default Communication Device", often unset / a different/silent endpoint.
        var enumerator = new MMDeviceEnumerator();
        MMDevice device;
        if (!string.IsNullOrEmpty(DeviceId))
        {
            try { device = enumerator.GetDevice(DeviceId); }
            catch { device = enumerator.GetDefaultAudioEndpoint(DataFlow.Capture, Role.Console); }
        }
        else
        try { device = enumerator.GetDefaultAudioEndpoint(DataFlow.Capture, Role.Console); }
        catch { device = enumerator.GetDefaultAudioEndpoint(DataFlow.Capture, Role.Communications); }
        Diag.Log($"mic device: \"{device.FriendlyName}\"");

        _capture = new WasapiCapture(device);

        var srcFormat = _capture.WaveFormat;
        Diag.Log($"mic format: {srcFormat} ({srcFormat.SampleRate}Hz {srcFormat.Channels}ch {srcFormat.BitsPerSample}bit {srcFormat.Encoding})");

        _buffer = new BufferedWaveProvider(srcFormat)
        {
            DiscardOnBufferOverflow = true,
            BufferDuration = TimeSpan.FromSeconds(2),
            // CRITICAL: default is true, which makes Read() PAD WITH SILENCE to the requested
            // size — so the "while (Read > 0)" pull loop below never ends and floods the engine
            // with millions of zero samples, burying the real speech (→ nothing recognized).
            // false makes Read() return only the buffered samples (0 when drained).
            ReadFully = false,
        };

        // Build: source -> sample provider -> mono -> 16 kHz resample.
        ISampleProvider sample = _buffer.ToSampleProvider();
        if (srcFormat.Channels > 1)
            sample = sample.ToMono(); // down-mix
        // WdlResamplingSampleProvider ships with NAudio and works cross-arch.
        _resampledMono = new WdlResamplingSampleProvider(sample, TargetRate);

        _capture.DataAvailable += OnDataAvailable;
        _capture.RecordingStopped += OnRecordingStopped;

        _capture.StartRecording();
        IsRunning = true;
    }

    private void OnDataAvailable(object? sender, WaveInEventArgs e)
    {
        if (_buffer is null || _resampledMono is null) return;

        // Push raw bytes into the buffer, then pull resampled mono floats out.
        _buffer.AddSamples(e.Buffer, 0, e.BytesRecorded);

        // Read everything currently available from the resample chain.
        // Frame size: read in fixed chunks for steady cadence.
        // TODO(win): pick a chunk size aligned with the VAD window (Silero v5 = 512 @16k).
        const int chunk = 512;
        var floats = new float[chunk];
        int read;
        while ((read = _resampledMono.Read(floats, 0, chunk)) > 0)
        {
            if (read == chunk)
            {
                FrameAvailable?.Invoke(this, (float[])floats.Clone());
            }
            else
            {
                var tail = new float[read];
                Array.Copy(floats, tail, read);
                FrameAvailable?.Invoke(this, tail);
                break; // partial read => buffer drained
            }
        }
    }

    private void OnRecordingStopped(object? sender, StoppedEventArgs e)
    {
        // TODO(win): surface e.Exception (device unplugged etc.) to the tray as a balloon tip.
        IsRunning = false;
    }

    public void Stop()
    {
        if (!IsRunning) return;
        _capture?.StopRecording();
        IsRunning = false;
    }

    public void Dispose()
    {
        Stop();
        if (_capture is not null)
        {
            _capture.DataAvailable -= OnDataAvailable;
            _capture.RecordingStopped -= OnRecordingStopped;
            _capture.Dispose();
            _capture = null;
        }
    }
}
