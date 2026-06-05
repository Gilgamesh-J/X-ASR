// swift-tools-version: 6.0
// Vibe XASR — native macOS (arm64, macOS 13+) menu-bar voice-dictation app.
//
// Integrates three validated pieces:
//   * VibeUI         — SwiftUI HUD / Settings / MenuBar surfaces (path dep ../ui_swift)
//   * CFireRed       — FireRedVAD C/C++ shim (firered_vad.cc + knf csrc + kissfft)
//   * CSherpa        — sherpa-onnx streaming ASR C API (system-library modulemap)
//
// Optional (VIBE_LLAMA=1 build flag, AI 润色 Beta):
//   * CLlama         — llama.cpp C API (system-library modulemap). Off by default so a
//                      missing libllama never breaks the build; enable once
//                      native/llama/build.sh has produced dist/{include,lib}.
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

// AI 润色(Beta)后端:llama.cpp。仅当环境变量 VIBE_LLAMA 存在时编译进来(否则整体构建
// 照常,Refiner 后端不可用 → Beta 开关为安全 no-op)。libllama + llama.h 由
// native/llama/build.sh 产到 dist/{include,lib}。
let LLAMA_INC = "\(B)/native/llama/dist/include"
let LLAMA_LIB = "\(B)/native/llama/dist/lib"
let enableLlama = ProcessInfo.processInfo.environment["VIBE_LLAMA"] != nil

// ---- targets (CLlama appended only when enabled) ----
var allTargets: [Target] = [
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
]
if enableLlama {
    // ---- llama.cpp C API (system library: modulemap over llama.h) ----
    allTargets.append(.systemLibrary(
        name: "CLlama",
        path: "Sources/CLlama"
    ))
}

// ---- The app executable (llama deps/flags appended only when enabled) ----
var vibeDeps: [Target.Dependency] = [
    .product(name: "VibeUI", package: "ui_swift"),
    "CFireRed",
    "CSherpa",
]
var vibeSwift: [SwiftSetting] = [
    // Find Sparkle.framework's module for `import Sparkle`.
    .unsafeFlags(["-F", SPARKLE_DIR])
]
var vibeLinkFlags: [String] = [
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
]
if enableLlama {
    vibeDeps.append("CLlama")
    // -Xcc -I so clang resolves "llama.h" when importing the CLlama module;
    // -D VIBE_LLAMA via .define so LlamaRefiner.swift compiles in.
    vibeSwift.append(.unsafeFlags(["-Xcc", "-I", "-Xcc", LLAMA_INC]))
    vibeSwift.append(.define("VIBE_LLAMA"))
    vibeLinkFlags += [
        "-L", LLAMA_LIB,
        "-lllama",
        "-Xlinker", "-rpath", "-Xlinker", LLAMA_LIB,
    ]
}
allTargets.append(.executableTarget(
    name: "VibeIME",
    dependencies: vibeDeps,
    path: "Sources/VibeIME",
    swiftSettings: vibeSwift,
    linkerSettings: [
        .unsafeFlags(vibeLinkFlags)
    ]
))

let package = Package(
    name: "VibeIME",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(path: "../ui_swift")
    ],
    targets: allTargets,
    cxxLanguageStandard: .cxx17
)
