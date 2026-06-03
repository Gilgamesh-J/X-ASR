// ============================================================
//  Vibe XASR — History entry point (thin wrapper)
//
//  The History UI now lives in HistoryWorkspace (the redesigned 记录 workspace:
//  clustering + merge, multi-select + bulk ops, tags, calendar, keyboard, undo).
//  HistoryView is kept as the stable public entry so the host's openSettings /
//  openHistory call sites don't need to change.
// ============================================================

import SwiftUI

public struct HistoryView<Store: HistoryBridge & ObservableObject>: View {
    private let store: Store
    private let l10n: L10n
    public init(store: Store, l10n: L10n = .shared) {
        self.store = store
        self.l10n = l10n
    }
    public var body: some View {
        HistoryWorkspace(store: store, l10n: l10n)
    }
}
