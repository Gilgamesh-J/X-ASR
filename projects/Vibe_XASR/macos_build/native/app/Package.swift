// swift-tools-version: 6.0
// Vibe XASR — native macOS (arm64, macOS 13+) menu-bar voice-dictation app.
//
// Integrates three validated pieces:
//   * VibeUI         — SwiftUI HUD / Settings / MenuBar surfaces (path dep ../ui_swift)
//   * CFireRed       — FireRedVAD C/C++ shim (firered_vad.cc + knf csrc + kissfft)
//   * CSherpa        — sherpa-onnx streaming ASR C API (system-library modulemap)
//
// Toolchain: Xcode 26.5 / Swift 6.3 / arm64. Links sherpa's OWN onnxruntime
// 1.24.4 for BOTH sherpa and the firered shim (single ORT — see gotcha A).
import PackageDescription
import Foundation

// B = the macos_build/ root, derived from this manifest's location (no hardcoded
// absolute path → portable). This file lives at <B>/native/app/Package.swift, so
// strip three path components.
let B = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()   // .../native/app
    .deletingLastPathComponent()   // .../native
    .deletingLastPathComponent()   // .../<B> (macos_build)
    .path
let KNF = "\(B)/native/third_party/kaldi-native-fbank"      // include root for "kaldi-native-fbank/csrc/*.h"
let KISS = "\(B)/native/third_party/kissfft"                // kiss_fft.h / kiss_fftr.h
let ORT_INC = "\(B)/native/third_party/onnxruntime/include" // 1.22 headers OK to compile against
let SHERPA_LIB = "\(B)/native/sherpa/dist/sherpa-onnx-v1.13.2-osx-universal2-shared/lib"
let SPARKLE_DIR = "\(B)/native/third_party/sparkle"          // contains Sparkle.framework (universal) — auto-update

let package = Package(
    name: "VibeIME",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(path: "../ui_swift")
    ],
    targets: [
        // ---- sherpa-onnx C API (system library: just a modulemap) ----
        .systemLibrary(
            name: "CSherpa",
            path: "Sources/CSherpa"
        ),

        // ---- FireRedVAD shim: mixed C/C++ in one C-family target ----
        .target(
            name: "CFireRed",
            path: "Sources/CFireRed",
            // public header = include/firered_vad.h (+ module.modulemap)
            publicHeadersPath: "include",
            cSettings: [
                // kissfft .c needs the kissfft headers
                .unsafeFlags([
                    "-I", KISS,
                ])
            ],
            cxxSettings: [
                // firered_vad.cc (C++17 via cxxLanguageStandard below) needs the
                // knf root, kissfft and onnxruntime headers. Do NOT put -std here:
                // SwiftPM bleeds cxxSettings unsafeFlags onto the .c compiles too.
                .unsafeFlags([
                    "-I", KNF,
                    "-I", KISS,
                    "-I", ORT_INC,
                ])
            ]
        ),

        // ---- The app executable ----
        .executableTarget(
            name: "VibeIME",
            dependencies: [
                .product(name: "VibeUI", package: "ui_swift"),
                "CFireRed",
                "CSherpa",
            ],
            path: "Sources/VibeIME",
            swiftSettings: [
                // Find Sparkle.framework's module for `import Sparkle`.
                .unsafeFlags(["-F", SPARKLE_DIR])
            ],
            linkerSettings: [
                .unsafeFlags([
                    // sherpa-onnx C API + its OWN onnxruntime 1.24.4 (one ORT only)
                    "-L", SHERPA_LIB,
                    "-lsherpa-onnx-c-api",
                    "-lonnxruntime",
                    "-lc++",
                    // Sparkle auto-update framework
                    "-F", SPARKLE_DIR,
                    "-framework", "Sparkle",
                    // runtime: bundle layout first, then the dev lib dir as a fallback
                    "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
                    "-Xlinker", "-rpath", "-Xlinker", SHERPA_LIB,
                    "-Xlinker", "-rpath", "-Xlinker", SPARKLE_DIR,
                ])
            ]
        ),
    ],
    cxxLanguageStandard: .cxx17
)
