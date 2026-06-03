// swift-tools-version: 6.0
// Vibe XASR — VibeUI reusable SwiftUI surfaces (HUD / Settings / MenuBar).
// macOS 13+, arm64. Library target only; the host app links VibeUI and
// drives the views via the external `HUDModel` ObservableObject.
import PackageDescription

let package = Package(
    name: "VibeUI",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "VibeUI",
            targets: ["VibeUI"]
        )
    ],
    targets: [
        .target(
            name: "VibeUI",
            path: "Sources/VibeUI"
        )
    ]
)
