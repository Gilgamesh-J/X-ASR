using System;
using System.Collections.Generic;
using System.IO;
using System.Media;

namespace VibeXASR.Windows;

/// <summary>
/// Typeless-style "cue" sounds played when dictation STARTS / STOPS. All five timbres are
/// synthesized in-memory to a tiny 16-bit mono WAV (the low/med/high gain is baked into the
/// samples, so <see cref="SoundPlayer"/> needs no volume control) and cached. Playback is fully
/// independent of mic capture, so it never disturbs recording. Faithful port of macOS CueSound.swift.
/// </summary>
internal sealed class CueSound
{
    public static readonly CueSound Shared = new();

    private const int SampleRate = 44_100;
    private readonly Dictionary<string, SoundPlayer> _cache = new();
    private float _gain = 0.15f;   // low (default)

    /// <summary>Map the low/med/high preset to a playback gain (unknown → low).</summary>
    public static float GainFor(string? preset) => preset switch { "med" => 0.35f, "high" => 0.65f, _ => 0.15f };

    /// <summary>Set the gain from a low/med/high preset; clears the cache so re-renders bake it in.</summary>
    public void SetVolume(string? preset)
    {
        var g = GainFor(preset);
        if (Math.Abs(g - _gain) > 1e-4f)
        {
            _gain = g;
            foreach (var p in _cache.Values) p.Dispose();
            _cache.Clear();
        }
    }

    /// <summary>Play the start (<paramref name="start"/>=true) or stop cue for a timbre. Best-effort.</summary>
    public void Play(string? theme, bool start)
    {
        try
        {
            var t = Normalize(theme);
            var key = $"{t}|{(start ? "s" : "e")}|{_gain:F2}";
            if (!_cache.TryGetValue(key, out var sp))
            {
                sp = new SoundPlayer(new MemoryStream(RenderWav(Segments(t, start), _gain)));
                sp.Load();
                _cache[key] = sp;
            }
            sp.Play();
        }
        catch { /* audio device busy / missing → silent, never break dictation */ }
    }

    private static string Normalize(string? t) =>
        t is "tick" or "chime" or "soft" or "drop" or "marimba" ? t : "chime";

    // ---- timbre definitions ----

    private enum Wave { Sine, Triangle, FmBell }
    private readonly record struct Seg(double F0, double F1, double Dur, Wave Wave);

    private static List<Seg> Segments(string theme, bool start)
    {
        const double E5 = 659.25, B5 = 987.77, A5 = 880.0, C6 = 1046.5, D5 = 587.33, A4 = 440.0, G4 = 392.0, D4 = 293.66;
        switch (theme)
        {
            case "tick":                       // single short soft blip
                { double f = start ? A5 : E5; return new() { new Seg(f, f, 0.06, Wave.Sine) }; }
            case "soft":                       // mellow triangle
                { double f = start ? A4 : D4; return new() { new Seg(f, f, 0.16, Wave.Triangle) }; }
            case "drop":                       // pitch-sweep "bloop"
                return start ? new() { new Seg(D5, C6, 0.11, Wave.Sine) }
                             : new() { new Seg(C6, D5, 0.13, Wave.Sine) };
            case "marimba":                    // FM bell-ish, woody
                { double f = start ? G4 : D4; return new() { new Seg(f, f, start ? 0.16 : 0.18, Wave.FmBell) }; }
            default:                           // chime — rising on start, falling on stop
                return start ? new() { new Seg(E5, E5, 0.075, Wave.Sine), new Seg(B5, B5, 0.13, Wave.Sine) }
                             : new() { new Seg(B5, B5, 0.075, Wave.Sine), new Seg(E5, E5, 0.14, Wave.Sine) };
        }
    }

    // ---- synthesis ----

    private static byte[] RenderWav(List<Seg> segs, float gain)
    {
        var floats = new List<float>();
        double attackN = Math.Max(1.0, 0.004 * SampleRate);  // 4 ms attack
        double tailN = Math.Max(1.0, 0.003 * SampleRate);    // 3 ms fade-out (kills clicks)
        foreach (var seg in segs)
        {
            int n = Math.Max(1, (int)(seg.Dur * SampleRate));
            double phase = 0;
            for (int i = 0; i < n; i++)
            {
                double frac = (double)i / n;
                double f = seg.F0 + (seg.F1 - seg.F0) * frac;
                phase += 2 * Math.PI * f / SampleRate;
                double s = seg.Wave switch
                {
                    Wave.Triangle => 2 / Math.PI * Math.Asin(Math.Sin(phase)),
                    Wave.FmBell => Math.Sin(phase + 2.0 * Math.Sin(phase * 2.0)),
                    _ => Math.Sin(phase),
                };
                double env = Math.Min(i / attackN, 1.0) * Math.Exp(-3.2 * frac);
                double remaining = n - i;
                if (remaining < tailN) env *= remaining / tailN;
                floats.Add((float)(s * env * gain));
            }
        }
        return WavData(floats, SampleRate);
    }

    /// <summary>16-bit mono PCM WAV from float samples in [-1, 1].</summary>
    private static byte[] WavData(List<float> samples, int sampleRate)
    {
        const int bytesPerSample = 2;
        int dataSize = samples.Count * bytesPerSample;
        using var ms = new MemoryStream(44 + dataSize);
        using var w = new BinaryWriter(ms);
        void Str(string s) { foreach (var c in s) w.Write((byte)c); }
        Str("RIFF"); w.Write((uint)(36 + dataSize)); Str("WAVE");
        Str("fmt "); w.Write(16u); w.Write((ushort)1); w.Write((ushort)1);   // PCM, mono
        w.Write((uint)sampleRate); w.Write((uint)(sampleRate * bytesPerSample));
        w.Write((ushort)bytesPerSample); w.Write((ushort)16);                // block align, bits/sample
        Str("data"); w.Write((uint)dataSize);
        foreach (var s in samples) w.Write((short)(Math.Max(-1f, Math.Min(1f, s)) * 32767));
        w.Flush();
        return ms.ToArray();
    }
}
