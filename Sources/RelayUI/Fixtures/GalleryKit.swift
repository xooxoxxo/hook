import Foundation

/// RelayGallery's command line: `RelayGallery [outDir] [scene…] [--contrast] [--reduce-transparency] [--xl]`.
public struct GalleryOptions: Equatable, Sendable {
    public var outDir: String
    public var scenes: Set<String>
    public var contrast: Bool
    public var reduceTransparency: Bool
    public var xl: Bool

    public init(outDir: String = "build/gallery", scenes: Set<String> = [], contrast: Bool = false,
                reduceTransparency: Bool = false, xl: Bool = false) {
        self.outDir = outDir
        self.scenes = scenes
        self.contrast = contrast
        self.reduceTransparency = reduceTransparency
        self.xl = xl
    }

    /// `arguments` without argv[0]. The first argument that isn't a flag is the
    /// output folder; the rest are scene names. Unknown flags are ignored.
    public static func parse(_ arguments: [String]) -> GalleryOptions {
        var options = GalleryOptions()
        var sawOutDir = false
        for argument in arguments {
            switch argument {
            case "--contrast": options.contrast = true
            case "--reduce-transparency": options.reduceTransparency = true
            case "--xl": options.xl = true
            default:
                if argument.hasPrefix("--") { continue }
                if sawOutDir {
                    options.scenes.insert(argument)
                } else {
                    options.outDir = argument
                    sawOutDir = true
                }
            }
        }
        return options
    }

    public func wants(_ scene: String) -> Bool {
        scenes.isEmpty || scenes.contains(scene)
    }

    /// --xl text multiplier; 1.35 is iOS's xxxLarge-to-Large body ratio (23/17).
    public var textScale: CGFloat { xl ? 1.35 : 1 }

    public var fileSuffix: String {
        (contrast ? "-contrast" : "") + (reduceTransparency ? "-rt" : "") + (xl ? "-xl" : "")
    }
}

public struct GalleryEntry: Equatable, Sendable {
    public var scene: String
    public var files: [String]
    /// The scene paints a stand-in where the panel's sidebar material would be: translucent
    /// window background over the canvas, or the opaque window background under --reduce-transparency.
    public var standIn: Bool

    public init(scene: String, files: [String], standIn: Bool) {
        self.scene = scene
        self.files = files
        self.standIn = standIn
    }
}

/// `build/gallery/index.html`: every PNG in a grid, captioned with its scene and theme.
public enum GalleryIndex {
    public static func html(_ entries: [GalleryEntry]) -> String {
        var figures = ""
        for entry in entries {
            for file in entry.files {
                var caption = escape(entry.scene) + " · " + theme(of: file, scene: entry.scene)
                if entry.standIn { caption += " · panel material: stand-in" }
                figures += "<figure><img src=\"\(escape(file))\" alt=\"\(escape(file))\">"
                    + "<figcaption>\(caption)</figcaption></figure>\n"
            }
        }
        return """
        <!doctype html>
        <html lang="en"><head><meta charset="utf-8"><title>Relay gallery</title>
        <style>
        body { font: 13px -apple-system, system-ui, sans-serif; margin: 16px; background: #f2f2f2; color: #222; }
        main { display: flex; flex-wrap: wrap; gap: 24px; align-items: flex-start; }
        figure { margin: 0; }
        img { display: block; max-width: 100%; zoom: 0.5; border: 1px solid #ccc; }
        figcaption { margin-top: 6px; color: #555; }
        </style></head>
        <body><main>
        \(figures)</main></body></html>

        """
    }

    /// "light" or "dark" (plus the flag suffix) from "<scene>-<theme><suffix>.png".
    static func theme(of file: String, scene: String) -> String {
        var name = file
        if name.hasSuffix(".png") { name.removeLast(4) }
        if name.hasPrefix(scene + "-") { name.removeFirst(scene.count + 1) }
        return escape(name)
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
