// ============================================================
//  Vibe XASR — Design Tokens (Swift mirror of ui/assets/tokens.css)
//  深色优先,浅色为镜像。accent 渐变贯穿声波/CTA/聆听态/Logo。
//
//  Hex values, radii, spacing and motion are copied verbatim from
//  tokens.css so the SwiftUI surfaces are pixel-faithful to the mockups.
//  Colors are resolved per `ColorScheme` (dark = the :root defaults,
//  light = the [data-theme="light"] overrides).
// ============================================================

import SwiftUI

// MARK: - Hex → Color helper

public extension Color {
    /// Build a Color from a `#RRGGBB` / `#RRGGBBAA` hex string (sRGB).
    init(hex: String, opacity: Double = 1.0) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        var value: UInt64 = 0
        Scanner(string: s).scanHexInt64(&value)

        let r, g, b, a: Double
        switch s.count {
        case 8: // RRGGBBAA
            r = Double((value & 0xFF00_0000) >> 24) / 255
            g = Double((value & 0x00FF_0000) >> 16) / 255
            b = Double((value & 0x0000_FF00) >> 8) / 255
            a = Double(value & 0x0000_00FF) / 255
        default: // RRGGBB (and fallback)
            r = Double((value & 0xFF0000) >> 16) / 255
            g = Double((value & 0x00FF00) >> 8) / 255
            b = Double(value & 0x0000FF) / 255
            a = 1.0
        }
        self.init(.sRGB, red: r, green: g, blue: b, opacity: a * opacity)
    }
}

// MARK: - Token namespace

public enum Vibe {

    // ----- Color (scheme-aware) ---------------------------------------
    // Each token returns the dark value by default and the light mirror
    // when `scheme == .light`, matching tokens.css :root / [data-theme].
    public enum Palette {
        // Brand accents are scheme-independent.
        public static let accentA = Color(hex: "#7C5CFF") // --accent-a
        public static let accentB = Color(hex: "#38E1D6") // --accent-b
        public static let success = Color(hex: "#45D483") // --success
        public static let warn    = Color(hex: "#FFB020") // --warn
        public static let error   = Color(hex: "#FF5C66") // --error

        public static func bg(_ s: ColorScheme) -> Color {
            s == .light ? Color(hex: "#F6F6F8") : Color(hex: "#0E0E12")
        }
        public static func surface(_ s: ColorScheme) -> Color {
            s == .light ? Color(hex: "#FFFFFF") : Color(hex: "#1A1A22")
        }
        public static func surface2(_ s: ColorScheme) -> Color {
            s == .light ? Color(hex: "#EFEFF3") : Color(hex: "#24242E")
        }
        public static func text(_ s: ColorScheme) -> Color {
            s == .light ? Color(hex: "#1A1A22") : Color(hex: "#ECECF1")
        }
        public static func textMuted(_ s: ColorScheme) -> Color {
            s == .light ? Color(hex: "#71717F") : Color(hex: "#8A8A99")
        }
        /// Fainter than textMuted — timestamps, hints, faint metadata.
        /// design --text-faint #515b70 (dark) → a gray-violet faint in light.
        public static func textFaint(_ s: ColorScheme) -> Color {
            s == .light ? Color(hex: "#9C9CA9") : Color(hex: "#5A5A6B")
        }
        /// --hairline: rgba(255,255,255,.08) dark / rgba(0,0,0,.08) light
        public static func hairline(_ s: ColorScheme) -> Color {
            s == .light ? Color.black.opacity(0.08) : Color.white.opacity(0.08)
        }
        /// --hairline-strong: .14 dark / .12 light
        public static func hairlineStrong(_ s: ColorScheme) -> Color {
            s == .light ? Color.black.opacity(0.12) : Color.white.opacity(0.14)
        }
        /// --inner-stroke: .06 dark / .05 light
        public static func innerStroke(_ s: ColorScheme) -> Color {
            s == .light ? Color.black.opacity(0.05) : Color.white.opacity(0.06)
        }
        /// --accent-soft: rgba(124,92,255,.16) dark / .12 light
        public static func accentSoft(_ s: ColorScheme) -> Color {
            Color(hex: "#7C5CFF", opacity: s == .light ? 0.12 : 0.16)
        }
        /// --glass: rgba(26,26,34,.66) dark / rgba(255,255,255,.7) light
        public static func glass(_ s: ColorScheme) -> Color {
            s == .light ? Color.white.opacity(0.70) : Color(hex: "#1A1A22", opacity: 0.66)
        }
        /// Segmented "on" pill background — the mockup uses a slightly raised
        /// #34343f / #3a3a46 in dark, plain surface in light.
        public static func segOn(_ s: ColorScheme) -> Color {
            s == .light ? Color(hex: "#FFFFFF") : Color(hex: "#3A3A46")
        }
    }

    // ----- Accent gradient --------------------------------------------
    // --accent: linear-gradient(100deg, #7C5CFF 0%, #38E1D6 100%)
    // CSS 100deg ≈ flowing from lower-left toward upper-right.
    public static let accentGradient = LinearGradient(
        colors: [Palette.accentA, Palette.accentB],
        startPoint: UnitPoint(x: 0.0, y: 0.85),
        endPoint: UnitPoint(x: 1.0, y: 0.15)
    )

    /// Vertical waveform-bar gradient: linear-gradient(180deg, accent-a, accent-b)
    public static let waveformGradient = LinearGradient(
        colors: [Palette.accentA, Palette.accentB],
        startPoint: .top, endPoint: .bottom
    )

    // ----- Radii (px) --------------------------------------------------
    public enum Radius {
        public static let panel:   CGFloat = 16  // --r-panel
        public static let card:    CGFloat = 12  // --r-card
        public static let control: CGFloat = 8   // --r-control
        public static let pill:    CGFloat = 999 // --r-pill
    }

    // ----- Spacing scale (px) -----------------------------------------
    public enum Space {
        public static let s1: CGFloat = 4
        public static let s2: CGFloat = 8
        public static let s3: CGFloat = 12
        public static let s4: CGFloat = 16
        public static let s6: CGFloat = 24
        public static let s8: CGFloat = 32
    }

    // ----- Glass / blur ------------------------------------------------
    public static let glassBlur: CGFloat = 30 // --glass-blur

    // ----- Shadows -----------------------------------------------------
    public enum Shadow {
        // --shadow-float: 0 12px 40px rgba(0,0,0,.45) (dark) / rgba(20,20,40,.18) (light)
        public static func floatColor(_ s: ColorScheme) -> Color {
            s == .light ? Color(hex: "#141428", opacity: 0.18) : Color.black.opacity(0.45)
        }
        public static let floatRadius: CGFloat = 20 // SwiftUI blur ≈ css/2
        public static let floatY: CGFloat = 12

        // --shadow-card: 0 6px 24px rgba(0,0,0,.3) / rgba(20,20,40,.1)
        public static func cardColor(_ s: ColorScheme) -> Color {
            s == .light ? Color(hex: "#141428", opacity: 0.10) : Color.black.opacity(0.30)
        }
        public static let cardRadius: CGFloat = 12
        public static let cardY: CGFloat = 6
    }

    // ----- Motion ------------------------------------------------------
    public enum Motion {
        public static let durFast: Double = 0.120 // --dur-fast 120ms
        public static let dur: Double      = 0.150 // --dur 150ms
        // --ease-spring: cubic-bezier(0.34, 1.56, 0.64, 1) — overshoot
        public static let spring = Animation.spring(response: 0.32, dampingFraction: 0.62)
        // --ease-out: cubic-bezier(0.22, 1, 0.36, 1)
        public static let easeOut = Animation.timingCurve(0.22, 1, 0.36, 1, duration: dur)
    }

    // ----- Type --------------------------------------------------------
    public enum Fonts {
        /// UI font = system (SF Pro). SwiftUI's default already resolves to SF Pro.
        public static func ui(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
            .system(size: size, weight: weight)
        }

        /// Recognition / mono text. Prefer "JetBrains Mono" if installed,
        /// otherwise fall back to the system monospaced face. Resolved once.
        public static let monoFamily: String? = {
            #if canImport(AppKit)
            let candidates = ["JetBrains Mono", "JetBrainsMono-Regular", "SF Mono", "SFMono-Regular"]
            for name in candidates {
                if NSFont(name: name, size: 12) != nil { return name }
            }
            return nil
            #else
            return nil
            #endif
        }()

        public static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
            if let fam = monoFamily {
                return .custom(fam, fixedSize: size).weight(weight)
            }
            return .system(size: size, weight: weight, design: .monospaced)
        }
    }
}

// MARK: - Reusable view modifiers

/// A floating glass panel: vibrant material + inner stroke + float shadow,
/// matching `.hud` / `.panel` in the mockups.
public struct GlassPanel: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    var cornerRadius: CGFloat
    var extraGlow: Color? = nil
    var extraGlowRadius: CGFloat = 0

    public func body(content: Content) -> some View {
        content
            .background(
                ZStack {
                    // Vibrancy approximation of backdrop-filter: blur(30px).
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(.ultraThinMaterial)
                    // Tint toward the token --glass color over the material.
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(Vibe.Palette.glass(scheme))
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Vibe.Palette.innerStroke(scheme), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .shadow(color: Vibe.Shadow.floatColor(scheme),
                    radius: Vibe.Shadow.floatRadius, x: 0, y: Vibe.Shadow.floatY)
            .modifier(OptionalGlow(color: extraGlow, radius: extraGlowRadius))
    }
}

private struct OptionalGlow: ViewModifier {
    var color: Color?
    var radius: CGFloat
    func body(content: Content) -> some View {
        if let color {
            content.shadow(color: color, radius: radius)
        } else {
            content
        }
    }
}

public extension View {
    /// Apply the floating glass treatment used by the HUD and menu panel.
    func glassPanel(cornerRadius: CGFloat,
                    glow: Color? = nil,
                    glowRadius: CGFloat = 0) -> some View {
        modifier(GlassPanel(cornerRadius: cornerRadius,
                            extraGlow: glow, extraGlowRadius: glowRadius))
    }
}
