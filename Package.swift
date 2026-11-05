// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Relay",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "RelayCore"),
        // Option B: an empty slot for a crash-reporting SDK adapter; no dependency yet.
        .target(name: "HookTelemetry"),
        .target(
            name: "RelayUI",
            dependencies: ["RelayCore"],
            // The document viewer's vendored marked and DOMPurify, and its renderer; the
            // menu-bar glyphs; the new-ask notification's fish.
            resources: [.copy("Resources/Viewer"), .copy("Resources/MenuBar"), .copy("Resources/Notification")]
        ),
        .executableTarget(name: "Relay", dependencies: ["RelayCore", "RelayUI"]),
        .executableTarget(name: "RelayGallery", dependencies: ["RelayCore", "RelayUI"]),
        .testTarget(
            name: "RelayCoreTests",
            dependencies: ["RelayCore"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(name: "RelayUITests", dependencies: ["RelayUI", "RelayCore"]),
    ]
)
