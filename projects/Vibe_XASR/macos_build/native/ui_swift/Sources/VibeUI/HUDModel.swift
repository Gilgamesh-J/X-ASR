// ============================================================
//  Vibe XASR — HUDModel
//  The external, observable interface the host app drives. The engine
//  pushes phase / audio level / partial text / elapsed into this object;
//  `HUDView` (and the expanded/radical forms) bind to it live.
//
//  Phases mirror hud.jsx: idle, empty("在听…"), speaking, pause,
//  finalizing, done(已插入), cancel(已取消), error(...去设置).
// ============================================================

import SwiftUI
import Combine

@MainActor
public final class HUDModel: ObservableObject {

    /// Lifecycle of a single dictation pass.
    public enum Phase: String, Sendable, CaseIterable {
        case idle        // hidden
        case empty       // listening, no speech yet → placeholder "在听…"
        case speaking    // audio + streaming partial text + caret "▌"
        case pause       // inter-sentence silence → flat waveform + "…"
        case finalizing  // released; bouncing in, orb ✓
        case polishing   // 等云端/本地大模型润色返回 → 动态"润色中"，慢了给「立即插入」
        case done        // inserted at cursor → "已插入"
        case cancel      // Esc/discard → orb ✕, "已取消"
        case error       // mic/permission/clipping → glyph + reason + 去设置

        /// Whether the listening waveform + timer should be shown.
        public var isListening: Bool {
            self == .empty || self == .speaking || self == .pause
        }
        /// Whether the orb shows the success ✓ glyph.
        public var isDone: Bool {
            self == .finalizing || self == .done
        }
        /// Whether the HUD is on-screen at all.
        public var isVisible: Bool { self != .idle }
    }

    /// Visual form factor. Compact is the default pill.
    public enum Form: String, Sendable, CaseIterable {
        case compact
        case expanded
        case radical
    }

    /// Structured error payload shown in the error phase.
    public struct ErrorInfo: Equatable, Sendable {
        public var icon: String   // e.g. "🎙" / "🔒" / "📈"
        public var title: String  // e.g. "找不到麦克风"
        public var reason: String // e.g. "请插入或选择一个输入设备"
        public init(icon: String, title: String, reason: String) {
            self.icon = icon; self.title = title; self.reason = reason
        }
    }

    // MARK: Published state (the app writes these)

    /// Current lifecycle phase.
    @Published public var phase: Phase = .idle
    /// Audio amplitude envelope, 0...1, drives the waveform height.
    @Published public var level: Double = 0
    /// Streaming partial → final recognition text (monospaced line).
    @Published public var partialText: String = ""
    /// Pre-formatted listening timer, e.g. "0:07" / "1:23".
    @Published public var elapsed: String = "0:00"
    /// Populated only while `phase == .error`.
    @Published public var errorInfo: ErrorInfo?
    /// 润色等待过久(超过阈值)→ true,HUD 显示「立即插入 ✓」按钮(用规则版立即插入)。
    @Published public var polishSlow = false
    /// 一次性提示(如「大模型返回较慢，可换更快的模型」)。nil = 不显示。
    @Published public var polishHint: String?
    /// 「立即插入」回调(host 设置:取消润色、插规则版)。HUD 按钮点它。
    public var onInsertNow: (@MainActor () -> Void)?

    public init() {}

    // MARK: Convenience drivers (optional helpers for the host app)

    /// Atomically move to `error` with a payload.
    public func fail(icon: String, title: String, reason: String) {
        errorInfo = ErrorInfo(icon: icon, title: title, reason: reason)
        phase = .error
    }

    /// Reset to the hidden idle state and clear transient fields.
    public func reset() {
        phase = .idle
        level = 0
        partialText = ""
        elapsed = "0:00"
        errorInfo = nil
        polishSlow = false
        polishHint = nil
    }

    /// Format a duration (seconds) into the mm:ss style the HUD expects
    /// (m:SS, no leading hour) — useful for wiring an engine clock.
    public static func formatElapsed(_ seconds: Int) -> String {
        let m = seconds / 60
        let s = seconds % 60
        return "\(m):\(String(format: "%02d", s))"
    }

    // MARK: Demo / preview fixtures

    /// A model frozen in `.speaking` with the code-switch sample line.
    public static func previewSpeaking() -> HUDModel {
        let m = HUDModel()
        m.phase = .speaking
        m.level = 0.85
        m.partialText = "把这个 function 改成 async"
        m.elapsed = "0:07"
        return m
    }

    public static func previewPause() -> HUDModel {
        let m = HUDModel()
        m.phase = .pause
        m.level = 0.08
        m.partialText = "帮我把这个 function 改成 async,"
        m.elapsed = "0:09"
        return m
    }

    public static func previewError() -> HUDModel {
        let m = HUDModel()
        m.fail(icon: "🔒", title: "未授权麦克风",
               reason: "需要在系统设置里允许 Vibe XASR 访问麦克风")
        return m
    }

    public static func previewDone() -> HUDModel {
        let m = HUDModel()
        m.phase = .done
        m.partialText = "提醒我下午三点开会"
        return m
    }
}
