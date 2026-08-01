// swift-tools-version: 6.0
// SHRED — Skateboarding High-Rate Event Detection
//
// Single-package workspace (ADR-0001): module boundaries from docs/spec/04-architecture.md §2
// are enforced by the target dependency graph below. DetectionKit and ShredCore must stay
// buildable on Linux (NFR-8); CI runs `swift build && swift test` on Ubuntu.
import PackageDescription

let strict: [SwiftSetting] = [
    .enableUpcomingFeature("ExistentialAny"),
]

let package = Package(
    name: "Shred",
    platforms: [
        .iOS("18.0"),
        .macOS("15.0"),
    ],
    products: [
        .library(name: "ShredCore", targets: ["ShredCore"]),
        .library(name: "DetectionKit", targets: ["DetectionKit"]),
        .library(name: "TelemetryStore", targets: ["TelemetryStore"]),
        .library(name: "RouteKit", targets: ["RouteKit"]),
        .library(name: "CaptureKit", targets: ["CaptureKit"]),
        .library(name: "SessionEngine", targets: ["SessionEngine"]),
        .library(name: "HealthBridge", targets: ["HealthBridge"]),
        .library(name: "FeatureUI", targets: ["FeatureUI"]),
        .executable(name: "fixture-synth", targets: ["FixtureSynth"]),
        .executable(name: "shred-replay", targets: ["ShredReplay"]),
    ],
    targets: [
        // ── Pure core (Linux-buildable) ─────────────────────────────────────
        .target(name: "ShredCore", swiftSettings: strict),
        .target(name: "DetectionKit", dependencies: ["ShredCore"], swiftSettings: strict),
        .target(name: "TelemetryStore", dependencies: ["ShredCore"], swiftSettings: strict),
        .target(name: "RouteKit", dependencies: ["ShredCore"], swiftSettings: strict),
        .target(
            name: "SessionEngine",
            dependencies: ["ShredCore", "DetectionKit", "TelemetryStore", "RouteKit", "CaptureKit"],
            swiftSettings: strict),

        // ── Platform adapters (compile to stubs off-iOS via #if canImport) ──
        .target(name: "CaptureKit", dependencies: ["ShredCore"], swiftSettings: strict),
        .target(name: "HealthBridge", dependencies: ["ShredCore"], swiftSettings: strict),
        .target(
            name: "FeatureUI",
            dependencies: ["ShredCore", "SessionEngine", "RouteKit", "TelemetryStore", "HealthBridge"],
            swiftSettings: strict),

        // ── Tools ───────────────────────────────────────────────────────────
        .target(
            name: "SynthKit",
            dependencies: ["ShredCore", "TelemetryStore"],
            swiftSettings: strict),
        .executableTarget(
            name: "FixtureSynth",
            dependencies: ["ShredCore", "TelemetryStore", "SynthKit"],
            swiftSettings: strict),
        .executableTarget(
            name: "ShredReplay",
            dependencies: ["ShredCore", "DetectionKit", "TelemetryStore", "SessionEngine"],
            swiftSettings: strict),

        // ── Tests ───────────────────────────────────────────────────────────
        .testTarget(name: "ShredCoreTests", dependencies: ["ShredCore"]),
        .testTarget(
            name: "DetectionKitTests", dependencies: ["DetectionKit", "ShredCore", "SynthKit"]),
        .testTarget(name: "TelemetryStoreTests", dependencies: ["TelemetryStore", "ShredCore"]),
        .testTarget(name: "RouteKitTests", dependencies: ["RouteKit", "ShredCore"]),
        .testTarget(
            name: "SessionEngineTests",
            dependencies: [
                "SessionEngine", "ShredCore", "CaptureKit", "SynthKit", "DetectionKit",
                "TelemetryStore",
            ]),
    ]
)
