import AppKit
import AVFoundation
import ApplicationServices
import IOKit.hid

/// Thin wrappers around the three TCC permissions the app needs, plus the
/// "open the right System Settings pane" deep links. Kept in the VibeIME target
/// (it imports AVFoundation / IOKit / ApplicationServices); the SwiftUI
/// onboarding in VibeUI drives it via injected closures so the UI library stays
/// framework-light.
enum Permissions {

    /// Tri-state used by the onboarding so it can show ✓ (granted), neutral
    /// (not yet asked) or ✕ (explicitly denied).
    enum State {
        case granted
        case notDetermined
        case denied

        var isGranted: Bool { self == .granted }
    }

    // MARK: Microphone (AVCaptureDevice .audio)

    static func micState() -> State {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:    return .granted
        case .notDetermined: return .notDetermined
        case .denied, .restricted: return .denied
        @unknown default:    return .denied
        }
    }

    /// Prompt for microphone access (no-op if already decided).
    static func requestMic() {
        AVCaptureDevice.requestAccess(for: .audio) { _ in }
    }

    /// Open the Microphone pane in System Settings (used once mic is denied —
    /// requestAccess no longer prompts after a denial).
    static func openMicrophoneSettings() {
        openSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    }

    // MARK: Accessibility (AXIsProcessTrusted)

    static func accessibilityGranted() -> Bool {
        AXIsProcessTrusted()
    }

    /// True if a text-editable element currently holds keyboard focus (so inserted
    /// text has somewhere to land). When false, the caller shows the result for the
    /// user to copy instead of typing into the void.
    static func hasTextInputFocus() -> Bool {
        // Can't query AX → don't nag; assume there's somewhere to insert.
        guard AXIsProcessTrusted() else { return true }
        let system = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focusedRef)
        // LENIENT: a strict role/settable check wrongly rejected many real fields
        // (esp. Electron editors), so the copy dialog popped every time. Treat ANY
        // focused element as insertable; only "nothing focused at all" (e.g. the
        // Finder desktop) counts as nowhere to insert.
        guard err == .success, let focused = focusedRef,
              CFGetTypeID(focused) == AXUIElementGetTypeID() else { return false }
        _ = focused
        return true
    }

    /// Trigger the system "allow Accessibility" prompt and open the pane.
    static func requestAccessibility() {
        // `kAXTrustedCheckOptionPrompt` is a global `var` (CFStringRef) that
        // Swift 6 flags as not concurrency-safe to dereference. Its documented
        // value is the literal key string, so use that directly.
        let opt = "AXTrustedCheckOptionPrompt"
        _ = AXIsProcessTrustedWithOptions([opt: true] as CFDictionary)
        openSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    // MARK: Input Monitoring (IOHID listen-event)

    static func inputMonitoringGranted() -> Bool {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    }

    /// Request listen-event access and open the Input Monitoring pane.
    static func requestInputMonitoring() {
        _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        openSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
    }

    // MARK: helpers

    static func openSettings(_ urlString: String) {
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }
}
