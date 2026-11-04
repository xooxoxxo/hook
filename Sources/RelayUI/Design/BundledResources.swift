import Foundation

/// Finds a folder that RelayUI ships with (`.copy` in Package.swift): in Hook.app's Resources
/// (scripts/build.sh copies it there), else in the SwiftPM resource bundle next to the
/// executable (the gallery) or the test bundle. Never `Bundle.module`, which stops the app
/// when its build folder is gone.
enum BundledResources {
    static let bundleName = "Relay_RelayUI.bundle"

    /// The first `name` folder that holds `probe`.
    static func folder(_ name: String, containing probe: String) -> URL? {
        var candidates: [URL] = []
        if let resources = Bundle.main.resourceURL { candidates.append(resources.appending(path: name)) }
        candidates.append(Bundle.main.bundleURL.appending(path: bundleName).appending(path: name))
        let here = Bundle(for: BundleMarker.self).bundleURL
        candidates.append(here.deletingLastPathComponent().appending(path: bundleName).appending(path: name))
        candidates.append(here.appending(path: "Contents/Resources").appending(path: bundleName).appending(path: name))
        return candidates.first { FileManager.default.fileExists(atPath: $0.appending(path: probe).path) }
    }
}

private final class BundleMarker {}
