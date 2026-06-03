// ============================================================
//  Vibe XASR — Pad (便笺) window
//  An editable scratchpad hosting a SwiftUI TextEditor. Dictation finals can be
//  appended into it (toggle "听写写入便笺" in Settings). Copy-all + clear.
//  Faithful to the design tokens. Localized via L10n.
// ============================================================

import SwiftUI
import AppKit

/// The Pad window content. Generic over the host's pad store (an
/// ObservableObject conforming to PadBridge) so VibeUI need not know the app
/// target's concrete type while still binding the editor two-way + live-updating
/// when dictation appends text.
public struct PadView<Store: PadBridge & ObservableObject>: View {
    @ObservedObject private var store: Store
    @ObservedObject private var l10n: L10n
    @Environment(\.colorScheme) private var scheme

    @State private var toast: String?

    public init(store: Store, l10n: L10n = .shared) {
        self.store = store
        self.l10n = l10n
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Vibe.Palette.hairline(scheme))
            editor
            Divider().overlay(Vibe.Palette.hairline(scheme))
            footer
        }
        .frame(minWidth: 460, minHeight: 380)
        .background(Vibe.Palette.surface(scheme))
    }

    private var header: some View {
        HStack {
            HStack(spacing: 9) {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Vibe.accentGradient)
                    .frame(width: 22, height: 22)
                    .overlay(LogoBars(heights: [5, 11, 7], barW: 2, gap: 2))
                Text(l10n.t("pad.title"))
                    .font(Vibe.Fonts.ui(14, weight: .semibold))
                    .foregroundStyle(Vibe.Palette.text(scheme))
            }
            Spacer()
            if let toast {
                Text(toast)
                    .font(Vibe.Fonts.ui(12, weight: .medium))
                    .foregroundStyle(Vibe.Palette.success)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(Vibe.Palette.surface2(scheme))
    }

    private var editor: some View {
        ZStack(alignment: .topLeading) {
            // Placeholder when empty.
            if store.padText.isEmpty {
                Text(l10n.t("pad.placeholder"))
                    .font(Vibe.Fonts.mono(13))
                    .foregroundStyle(Vibe.Palette.textMuted(scheme))
                    .padding(.horizontal, 20).padding(.vertical, 18)
                    .allowsHitTesting(false)
            }
            TextEditor(text: Binding(get: { store.padText },
                                     set: { store.padText = $0 }))
                .font(Vibe.Fonts.mono(14))
                .foregroundStyle(Vibe.Palette.text(scheme))
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 14).padding(.vertical, 12)
        }
        .background(Vibe.Palette.surface(scheme))
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text("\(store.padText.count)")
                .font(Vibe.Fonts.mono(11))
                .foregroundStyle(Vibe.Palette.textMuted(scheme))
            Spacer()
            MButton(title: l10n.t("copy.all"), kind: .ghost) {
                copyAll()
            }
            MButton(title: l10n.t("clear"), kind: .danger) {
                store.clear()
                flash(l10n.t("pad.cleared"))
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(Vibe.Palette.surface2(scheme))
    }

    private func copyAll() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(store.padText, forType: .string)
        flash(l10n.t("history.copied"))
    }

    private func flash(_ msg: String) {
        withAnimation { toast = msg }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            withAnimation { if toast == msg { toast = nil } }
        }
    }
}
