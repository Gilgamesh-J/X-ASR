// ============================================================
//  Vibe XASR — OnCall session viewer
//  A dialog listing the CURRENT OnCall session's entries (timestamp + text),
//  each selectable so any part can be copied, plus an Export button.
// ============================================================

import SwiftUI
import AppKit
import UniformTypeIdentifiers

public struct OnCallSessionView: View {
    @ObservedObject private var log: OnCallLog    // live; refreshes as utterances land
    @ObservedObject private var l10n = L10n.shared
    @Environment(\.colorScheme) private var scheme

    private var entries: [HistoryItem] { log.entries }   // chronological (oldest-first)

    public init(log: OnCallLog) { self.log = log }

    private func tt(_ zh: String, _ en: String) -> String {
        switch l10n.resolved { case .zh: return zh; default: return en }
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(tt("本次候机记录", "This OnCall session"))
                    .font(Vibe.Fonts.ui(14, weight: .semibold))
                    .foregroundStyle(Vibe.Palette.text(scheme))
                Text("\(entries.count)")
                    .font(Vibe.Fonts.mono(11))
                    .foregroundStyle(Vibe.Palette.textMuted(scheme))
                Spacer()
                if !entries.isEmpty {
                    MButton(title: tt("复制全部", "Copy all"), kind: .ghost) { copyAll() }
                    MButton(title: tt("导出", "Export"), kind: .ghost) { exportAll() }
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .background(Vibe.Palette.surface2(scheme))
            Divider().overlay(Vibe.Palette.hairline(scheme))

            if entries.isEmpty {
                VStack { Spacer()
                    Text(tt("本次候机暂无识别记录", "Nothing captured this session yet"))
                        .font(Vibe.Fonts.ui(13)).foregroundStyle(Vibe.Palette.textMuted(scheme))
                    Spacer() }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(entries) { e in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(fmt.string(from: e.date))
                                    .font(Vibe.Fonts.mono(10.5))
                                    .foregroundStyle(Vibe.Palette.textMuted(scheme))
                                Text(e.text)
                                    .font(Vibe.Fonts.mono(13))
                                    .foregroundStyle(Vibe.Palette.text(scheme))
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(16)
                }
            }
        }
        .frame(minWidth: 440, minHeight: 380)
        .background(Vibe.Palette.surface(scheme))
    }

    private var plain: String {
        entries.map { "[\(fmt.string(from: $0.date))] \($0.text)" }.joined(separator: "\n")
    }

    private func copyAll() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(plain, forType: .string)
    }

    private func exportAll() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "vibe-oncall-session.txt"
        panel.allowedContentTypes = [.plainText]
        panel.isExtensionHidden = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? Data(plain.utf8).write(to: url, options: .atomic)
    }
}

private let fmt: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return f
}()
