import Foundation
import VibeUI

/// Backing store for the built-in Pad (便笺).
///
/// Holds the editable text and persists it to
/// `~/Library/Application Support/VibeXASR/pad.txt` so notes survive relaunch.
/// Dictation finals are appended via `appendDictation` when the user enables
/// "听写写入便笺" (SettingsStore.padWriteEnabled) — this works even while the Pad
/// window is closed, so reopening shows the accumulated text.
///
/// `@Published text` lets the SwiftUI TextEditor bind two-way; writes are
/// debounced onto a serial queue.
@MainActor
final class PadStore: ObservableObject, PadBridge {

    static let shared = PadStore()

    @Published var text: String = "" {
        didSet { persistAsync() }
    }

    private let queue = DispatchQueue(label: "com.xasr.vibexasr.pad")
    private let fileURL: URL

    init() {
        self.fileURL = ModelPaths.appSupportDir().appendingPathComponent("pad.txt")
        if let s = try? String(contentsOf: fileURL, encoding: .utf8) {
            // Seed without re-triggering a write for the load itself.
            _text = Published(initialValue: s)
        }
    }

    // MARK: PadBridge

    var padText: String {
        get { text }
        set { text = newValue }
    }

    /// Append a dictation final, inserting a separating space/newline as needed.
    func appendDictation(_ s: String) {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if text.isEmpty {
            text = trimmed
        } else if text.hasSuffix("\n") {
            text += trimmed
        } else {
            text += " " + trimmed
        }
    }

    func clear() { text = "" }

    private func persistAsync() {
        let snapshot = text
        let url = fileURL
        queue.async { try? snapshot.write(to: url, atomically: true, encoding: .utf8) }
    }
}
