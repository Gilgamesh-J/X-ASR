import AppKit

// Vibe XASR entry point. The AppDelegate owns the status item, HUD panel,
// engine and onboarding window. The activation policy (Dock icon vs menu-bar-
// only) is decided in applicationDidFinishLaunching from SettingsStore, so it
// is NOT forced here.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
