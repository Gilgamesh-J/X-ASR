import Foundation
import ServiceManagement

/// Thin wrapper over `SMAppService.mainApp` (macOS 13+) to register/unregister
/// the app as a login item, reflecting `SettingsStore.launchAtLogin`.
///
/// Best-effort: when running the bare dev executable (not a registered .app
/// bundle) SMAppService can throw — we log and ignore so dictation still works.
enum LaunchAtLogin {

    static func setEnabled(_ enabled: Bool) {
        let service = SMAppService.mainApp
        do {
            if enabled {
                if service.status != .enabled {
                    try service.register()
                }
            } else {
                if service.status == .enabled {
                    try service.unregister()
                }
            }
        } catch {
            FileHandle.standardError.write(
                "[VibeIME] launch-at-login \(enabled ? "register" : "unregister") failed: \(error)\n"
                    .data(using: .utf8)!)
        }
    }

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }
}
