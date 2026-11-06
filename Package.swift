// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Relay",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [.library(name: "RelayCore", targets: ["RelayCore"]),
               .library(name: "RelayUI", targets: ["RelayUI"])],
    targets: [
        .target(name: "RelayCore"),
        .target(name: "RelayMacCore", dependencies: ["RelayCore"]),
        // Option B: an empty slot for a crash-reporting SDK adapter; no dependency yet.
        .target(name: "HookTelemetry"),
        .target(name: "RelayUI", dependencies: ["RelayCore"]),
        .target(name: "RelayUIMac", dependencies: ["RelayCore", "RelayMacCore", "RelayUI"],
                resources: [.copy("Resources/Viewer"), .copy("Resources/MenuBar"), .copy("Resources/Notification")]),
        .executableTarget(name: "Relay", dependencies: ["RelayCore", "RelayMacCore", "RelayUI", "RelayUIMac"]),
        .executableTarget(name: "RelayGallery", dependencies: ["RelayCore", "RelayUI", "RelayUIMac"]),
        .testTarget(
            name: "RelayCoreTests",
            dependencies: ["RelayCore"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(name: "RelayMacCoreTests", dependencies: ["RelayMacCore", "RelayCore"], resources: [.copy("Fixtures")]),
        // Each UI test target compiles symlinks to the canonical test-only support files.
        // Xcode does not allow a test target to depend on another test target.
        .testTarget(name: "RelayUITests", dependencies: ["RelayUI", "RelayCore"]),
        .testTarget(name: "RelayUIMacTests", dependencies: ["RelayUIMac", "RelayUI", "RelayCore", "RelayMacCore"]),
    ]
)
