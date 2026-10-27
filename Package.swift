// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Relay",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "RelayCore"),
        .target(
            name: "RelayUI",
            dependencies: ["RelayCore"],
            // The document viewer's vendored marked and DOMPurify, and its renderer.
            resources: [.copy("Resources/Viewer")]
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
