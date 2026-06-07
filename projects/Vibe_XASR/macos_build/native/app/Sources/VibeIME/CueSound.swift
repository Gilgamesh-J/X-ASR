import Foundation
import AVFoundation

/// Subtle "cue" sounds played when dictation STARTS / STOPS.
///
/// All timbres are synthesized in-memory (no bundled audio assets → nothing extra
/// to sign/notarize) and rendered once to a tiny 16-bit WAV, then cached as an
/// `AVAudioPlayer`. Playback uses `AVAudioPlayer` (its own output unit) and is
/// completely independent of `Mic`'s input `AVAudioEngine`, so it never interferes
/// with capture.
@MainActor
final class CueSound {
    static let shared = CueSound()

    /// Selectable timbres. `rawValue` is what `SettingsStore` persists.
    enum Theme: String, CaseIterable {
        case tick, chime, soft, drop, marimba
    }

    private let sampleRate = 44_100.0
    private var cache: [String: AVAudioPlayer] = [:]

    /// Playback gain (0–1), driven by the user's 低/中/高 preference. Default low
    /// (the previous fixed level, 0.32, was "a bit loud"). Applied at play time so
    /// it affects cached players too.
    var gain: Float = 0.15

    /// Map the low/med/high preset to a playback gain. Default (unknown) = low.
    static func gain(for preset: String) -> Float {
        switch preset {
        case "med":  return 0.35
        case "high": return 0.65
        default:     return 0.15   // low (default)
        }
    }

    /// Play the start (`start == true`) or stop cue for a theme. No-ops on failure.
    func play(theme rawTheme: String, start: Bool) {
        let theme = Theme(rawValue: rawTheme) ?? .chime
        let key = "\(theme.rawValue)|\(start ? "s" : "e")"
        let player: AVAudioPlayer
        if let p = cache[key] {
            player = p
        } else if let p = build(theme, start: start) {
            cache[key] = p
            player = p
        } else {
            return
        }
        player.currentTime = 0
        player.volume = gain
        player.play()
    }

    private func build(_ theme: Theme, start: Bool) -> AVAudioPlayer? {
        let wav = renderWAV(segments(theme, start: start))
        guard let p = try? AVAudioPlayer(data: wav) else { return nil }
        p.volume = gain   // refreshed per-play in play(); set here for first play too
        p.prepareToPlay()
        return p
    }

    // MARK: - Timbre definitions

    /// One tone segment: glide `f0 → f1` over `dur` seconds with waveform `wave`.
    private struct Seg { var f0: Double; var f1: Double; var dur: Double; var wave: Wave }
    private enum Wave { case sine, triangle, fmBell }

    private func segments(_ theme: Theme, start: Bool) -> [Seg] {
        let E5 = 659.25, B5 = 987.77, A5 = 880.0, C6 = 1046.5, D5 = 587.33
        let A4 = 440.0, G4 = 392.0, D4 = 293.66
        switch theme {
        case .tick:                       // single short soft blip
            let f = start ? A5 : E5
            return [Seg(f0: f, f1: f, dur: 0.06, wave: .sine)]
        case .chime:                      // two notes — rising on start, falling on stop
            return start
                ? [Seg(f0: E5, f1: E5, dur: 0.075, wave: .sine), Seg(f0: B5, f1: B5, dur: 0.13, wave: .sine)]
                : [Seg(f0: B5, f1: B5, dur: 0.075, wave: .sine), Seg(f0: E5, f1: E5, dur: 0.14, wave: .sine)]
        case .soft:                       // mellow triangle
            let f = start ? A4 : D4
            return [Seg(f0: f, f1: f, dur: 0.16, wave: .triangle)]
        case .drop:                       // pitch-sweep "bloop"
            return start
                ? [Seg(f0: D5, f1: C6, dur: 0.11, wave: .sine)]
                : [Seg(f0: C6, f1: D5, dur: 0.13, wave: .sine)]
        case .marimba:                    // FM bell-ish, woody
            return start
                ? [Seg(f0: G4, f1: G4, dur: 0.16, wave: .fmBell)]
                : [Seg(f0: D4, f1: D4, dur: 0.18, wave: .fmBell)]
        }
    }

    // MARK: - Synthesis

    private func renderWAV(_ segs: [Seg]) -> Data {
        var floats: [Float] = []
        let attackN = max(1.0, 0.004 * sampleRate)   // 4 ms attack
        let tailN = max(1.0, 0.003 * sampleRate)     // 3 ms fade-out (kills clicks)
        for seg in segs {
            let n = max(1, Int(seg.dur * sampleRate))
            var phase = 0.0
            for i in 0..<n {
                let frac = Double(i) / Double(n)
                let f = seg.f0 + (seg.f1 - seg.f0) * frac
                phase += 2 * .pi * f / sampleRate
                let s: Double
                switch seg.wave {
                case .sine:     s = sin(phase)
                case .triangle: s = 2 / .pi * asin(sin(phase))
                case .fmBell:   s = sin(phase + 2.0 * sin(phase * 2.0))   // simple FM
                }
                var env = min(Double(i) / attackN, 1.0) * exp(-3.2 * frac)
                let remaining = Double(n - i)
                if remaining < tailN { env *= remaining / tailN }
                floats.append(Float(s * env))
            }
        }
        return Self.wavData(floats, sampleRate: Int(sampleRate))
    }

    /// 16-bit mono PCM WAV from float samples in [-1, 1].
    private static func wavData(_ samples: [Float], sampleRate: Int) -> Data {
        let bytesPerSample = 2
        let dataSize = samples.count * bytesPerSample
        var d = Data(capacity: 44 + dataSize)
        func u32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
        func u16(_ v: UInt16) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
        d.append("RIFF".data(using: .ascii)!)
        d.append(u32(UInt32(36 + dataSize)))
        d.append("WAVE".data(using: .ascii)!)
        d.append("fmt ".data(using: .ascii)!)
        d.append(u32(16))                                 // PCM fmt chunk size
        d.append(u16(1))                                  // PCM
        d.append(u16(1))                                  // mono
        d.append(u32(UInt32(sampleRate)))
        d.append(u32(UInt32(sampleRate * bytesPerSample)))// byte rate
        d.append(u16(UInt16(bytesPerSample)))             // block align
        d.append(u16(16))                                 // bits/sample
        d.append("data".data(using: .ascii)!)
        d.append(u32(UInt32(dataSize)))
        for s in samples {
            let v = Int16(max(-1.0, min(1.0, s)) * 32767)
            d.append(u16(UInt16(bitPattern: v)))
        }
        return d
    }
}
