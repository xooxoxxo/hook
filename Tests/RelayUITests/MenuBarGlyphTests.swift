import AppKit
import RelayCore
import Testing
@testable import RelayUI

/// The menu-bar glyphs: an outline hook while idle, a filled fish on the hook for a new ask.
/// Template images (black on transparent, so macOS tints them), 16 × 18 pt at @1x and @2x.
@Suite @MainActor struct MenuBarGlyphTests {
    @Test func tokens() {
        #expect(DS.Glyph.menuBarIdle == "menubar-idle")
        #expect(DS.Glyph.menuBarNew == "menubar-new")
        #expect(DS.Glyph.name(.idle) == DS.Glyph.menuBarIdle)
        #expect(DS.Glyph.name(.new) == DS.Glyph.menuBarNew)
        #expect(DS.Glyph.menuBarSize == CGSize(width: 16, height: 18))
        // One width for both glyphs, so the item never jumps when an ask arrives.
        #expect(DS.Metric.menuBarItem == 24)
        #expect(DS.Symbol.menuBarFallback == "checklist")
    }

    @Test(arguments: MenuBarGlyph.allCases)
    func loadsAsATemplate(_ glyph: MenuBarGlyph) throws {
        let image = try #require(MenuBarGlyphImage.image(glyph))
        #expect(image.isTemplate)
        #expect(image.size == DS.Glyph.menuBarSize)
        #expect(image.accessibilityDescription == glyph.accessibilityDescription)
        let pixels = image.representations.map { [$0.pixelsWide, $0.pixelsHigh] }
            .sorted { $0[0] < $1[0] }
        #expect(pixels == [[16, 18], [32, 36]])
        for rep in image.representations { #expect(rep.size == DS.Glyph.menuBarSize) }
    }

    /// A template's colour is thrown away, so any ink that isn't black is a mistake.
    @Test(arguments: MenuBarGlyph.allCases)
    func blackOnTransparent(_ glyph: MenuBarGlyph) throws {
        let image = try #require(MenuBarGlyphImage.image(glyph))
        for case let rep as NSBitmapImageRep in image.representations {
            var inked = 0
            for x in 0..<rep.pixelsWide {
                for y in 0..<rep.pixelsHigh {
                    guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), c.alphaComponent > 0 else { continue }
                    inked += 1
                    #expect(c.redComponent < 0.01 && c.greenComponent < 0.01 && c.blueComponent < 0.01)
                }
            }
            #expect(inked > 0)
        }
    }

    /// The filled fish carries far more ink than the outline hook: the files aren't swapped.
    @Test func theNewGlyphIsTheHeavierOne() throws {
        func ink(_ glyph: MenuBarGlyph) throws -> Double {
            let image = try #require(MenuBarGlyphImage.image(glyph))
            let rep = try #require(image.representations.compactMap { $0 as? NSBitmapImageRep }.max { $0.pixelsWide < $1.pixelsWide })
            var sum = 0.0
            for x in 0..<rep.pixelsWide {
                for y in 0..<rep.pixelsHigh { sum += Double(rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) }
            }
            return sum
        }
        #expect(try ink(.new) > 1.5 * ink(.idle))
    }

    /// The status item: the glyph for the state, the same length either way.
    @Test func statusImageFollowsTheState() throws {
        let idle = try #require(MenuBarGlyphImage.image(for: MenuBarState(count: 2)))
        let new = try #require(MenuBarGlyphImage.image(for: MenuBarState(count: 2, unseen: true)))
        #expect(idle.accessibilityDescription == "Hook")
        #expect(new.accessibilityDescription == "Hook, new ask")
        #expect(idle.size.width == new.size.width)
    }
}
