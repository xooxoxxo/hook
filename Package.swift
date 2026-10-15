// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Relay",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "RelayCore"),
        .executableTarget(name: "Relay", dependencies: ["RelayCore"]),
        .testTarget(
            name: "RelayCoreTests",
            dependencies: ["RelayCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
