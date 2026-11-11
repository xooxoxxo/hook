import RelayUI
import AppKit
import RelayCore

/// The menu-bar glyphs as template images: each file's @1x and @2x in one `NSImage` of
/// `DS.Glyph.menuBarSize` points, so AppKit picks the sharp one for the screen and tints it
/// for the menu bar. Nil when the files are missing (the caller falls back to a symbol).
@MainActor public enum MenuBarGlyphImage {
    private static var cache: [MenuBarGlyph: NSImage] = [:]

    public static func image(_ glyph: MenuBarGlyph) -> NSImage? {
        if let cached = cache[glyph] { return cached }
        let name = DS.Glyph.name(glyph)
        guard let folder = BundledResources.folder("MenuBar", containing: name + ".png") else { return nil }
        let image = NSImage(size: DS.Glyph.menuBarSize)
        for file in [name + ".png", name + "@2x.png"] {
            guard let rep = NSImageRep(contentsOf: folder.appending(path: file)) else { continue }
            rep.size = DS.Glyph.menuBarSize
            image.addRepresentation(rep)
        }
        guard !image.representations.isEmpty else { return nil }
        image.isTemplate = true
        image.accessibilityDescription = glyph.accessibilityDescription
        cache[glyph] = image
        return image
    }

    /// The glyph for the status item's state.
    public static func image(for state: MenuBarState) -> NSImage? {
        image(state.glyph)
    }
}
