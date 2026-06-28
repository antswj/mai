// swift-tools-version:6.0
import PackageDescription
import Foundation

// `swift test` uses the swift-testing framework. With Command Line Tools only (no
// full Xcode), that framework lives under CommandLineTools and is not on the
// default search path, so the test target adds it explicitly. The path can be
// overridden with MAI_TEST_FRAMEWORKS; the default covers a CLT-only machine and
// is harmlessly ignored on machines with full Xcode (where SwiftPM finds it itself).
let testFrameworks = ProcessInfo.processInfo.environment["MAI_TEST_FRAMEWORKS"]
    ?? "/Library/Developer/CommandLineTools/Library/Developer/Frameworks"
// Testing.framework loads lib_TestingInterop.dylib from this adjacent lib dir at runtime.
let testInteropLibs = ProcessInfo.processInfo.environment["MAI_TEST_INTEROP_LIBS"]
    ?? "/Library/Developer/CommandLineTools/Library/Developer/usr/lib"

// Mai: an ambient real-time awareness engine.
// MaiCore is the brain: plain Swift, zero UI-framework dependencies, so it can
// move to a device later. MaiApp is the SwiftUI face. Verified to build and run
// with Command Line Tools only (no full Xcode): `swift build`, `swift test`,
// `swift run Mai` (confirmed on Swift 6.3 / macOS 26, 2026-06).
let package = Package(
    name: "Mai",
    platforms: [
        .macOS(.v14) // required floor for the SwiftUI App lifecycle used by MaiApp
    ],
    products: [
        .library(name: "MaiCore", targets: ["MaiCore"]),
        .library(name: "MaiCapture", targets: ["MaiCapture"]),
        .executable(name: "Mai", targets: ["MaiApp"]),
        .executable(name: "MaiSmoke", targets: ["MaiSmoke"]),
        .executable(name: "MaiTests", targets: ["MaiTests"]),
    ],
    dependencies: [
        // Current, actively maintained SQLite wrapper (confirmed v7.11.1, 2026-06).
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.11.1"),
    ],
    targets: [
        .target(
            name: "MaiCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            resources: [
                // Prompt templates shared by the engine and the evals.
                .process("Prompts"),
            ]
        ),
        // Real platform capture (macOS): ScreenCaptureKit audio + screen, Soniox
        // streaming transcription, Gemini screen reads. Implements the MaiCore
        // Ears/Eyes contracts. Kept separate so MaiCore stays portable.
        .target(
            name: "MaiCapture",
            dependencies: ["MaiCore"]
        ),
        .executableTarget(
            name: "MaiApp",
            dependencies: ["MaiCore", "MaiCapture"]
        ),
        .executableTarget(
            name: "MaiSmoke",
            dependencies: ["MaiCore", "MaiCapture"]
        ),
        // Deterministic acceptance harness over the public engine + stubs. Runs
        // everywhere, including with Command Line Tools only, where `swift test`
        // (swift-testing) cannot run because that framework ships with full Xcode.
        .executableTarget(
            name: "MaiTests",
            dependencies: ["MaiCore", "MaiCapture"]
        ),
        .testTarget(
            name: "MaiCoreTests",
            dependencies: ["MaiCore"],
            resources: [
                .copy("Fixtures"),
            ],
            swiftSettings: [
                .unsafeFlags(["-F", testFrameworks]),
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-F", testFrameworks,
                    "-Xlinker", "-rpath", "-Xlinker", testFrameworks,
                    "-Xlinker", "-rpath", "-Xlinker", testInteropLibs,
                ]),
            ]
        ),
    ]
)
