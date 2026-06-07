// ============================================================
//  Vibe XASR — OnCall overlay (top-right, interactive)
//  Always-on standby. Shows live recognition; does NOT auto-type. The user
//  copies the text when ready, or stops (which also switches the mode back to
//  "说完插入"). Records keep flowing to history (tagged oncall) for safety.
// ============================================================

import SwiftUI

/// Live log of the current OnCall session — observed by both the overlay and the
/// session viewer so the viewer refreshes as new utterances land.
@MainActor public final class OnCallLog: ObservableObject {
    @Published public var entries: [HistoryItem] = []
    @Published public var paused: Bool = false
    public init() {}
}

public struct OnCallOverlay: View {
    @ObservedObject var model: HUDModel
    @ObservedObject var log: OnCallLog
    @ObservedObject private var l10n = L10n.shared
    @Environment(\.colorScheme) private var scheme
    private let onCopy: () -> Void
    private let onView: () -> Void
    private let onPause: () -> Void
    private let onStop: () -> Void

    public init(model: HUDModel, log: OnCallLog,
                onCopy: @escaping () -> Void,
                onView: @escaping () -> Void,
                onPause: @escaping () -> Void,
                onStop: @escaping () -> Void) {
        self.model = model
        self.log = log
        self.onCopy = onCopy
        self.onView = onView
        self.onPause = onPause
        self.onStop = onStop
    }

    private func tt(_ zh: String, _ en: String) -> String {
        switch l10n.resolved { case .zh, .zhHant: return zh; default: return en }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                Circle().fill(Vibe.Palette.error).frame(width: 8, height: 8)
                Text("OnCall")
                    .font(Vibe.Fonts.ui(12, weight: .semibold))
                    .foregroundStyle(Vibe.Palette.text(scheme))
                Spacer()
                Text(model.elapsed)
                    .font(Vibe.Fonts.mono(11))
                    .foregroundStyle(Vibe.Palette.textMuted(scheme))
            }
            ScrollView {
                Text(log.paused ? tt("已暂停", "Paused")
                     : (model.partialText.isEmpty
                        ? tt("候机中,识别到说话即显示…", "Standby — speak to capture…")
                        : model.partialText))
                    .font(Vibe.Fonts.mono(13))
                    .foregroundStyle(model.partialText.isEmpty
                                     ? Vibe.Palette.textMuted(scheme)
                                     : Vibe.Palette.text(scheme))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(height: 78)
            HStack(spacing: 7) {
                pill(tt("复制", "Copy"), filled: false, action: onCopy)
                pill(tt("查看", "View"), filled: false, action: onView)
                pill(log.paused ? tt("继续", "Resume") : tt("暂停", "Pause"), filled: false, action: onPause)
                pill(tt("停止", "Stop"), filled: true, action: onStop)
                Spacer()
            }
        }
        .padding(14)
        .frame(width: 330)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(Vibe.Palette.surface(scheme)))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(Vibe.Palette.hairline(scheme), lineWidth: 1))
        .shadow(color: .black.opacity(0.28), radius: 16, y: 6)
    }

    private func pill(_ title: String, filled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(Vibe.Fonts.ui(12.5, weight: .semibold))
                .foregroundStyle(filled ? .white : Vibe.Palette.text(scheme))
                .padding(.vertical, 6).padding(.horizontal, 14)
                .background(Capsule().fill(filled ? Vibe.Palette.error
                                                  : Vibe.Palette.surface2(scheme)))
        }
        .buttonStyle(.plain)
    }
}
