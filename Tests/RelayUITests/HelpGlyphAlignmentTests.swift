import AppKit
import SwiftUI
import Testing
@testable import RelayUI

/// Owner pick 2: the "?" sits on its label's capitals, whatever the label's text style.
@Suite @MainActor struct HelpGlyphAlignmentTests {
    /// The font a label of `style` uses at each site.
    private func font(_ style: HelpLabelStyle) -> Font {
        switch style {
        case .body: return DS.Font.body
        case .heading: return DS.Font.heading
        case .prose: return DS.Font.prose
        case .caption: return DS.Font.caption
        case .subheadline: return DS.Font.meta
        }
    }

    /// Renders "H" and the glyph in a baseline row, returning the vertical ink centres
    /// of the "H" (the first ink cluster) and of the glyph (the last).
    private func centres(_ style: HelpLabelStyle, scheme: ColorScheme) throws -> (h: CGFloat, glyph: CGFloat) {
        let size = NSSize(width: 120, height: 60)
        let background: Color = scheme == .dark ? .black : .white
        let row = HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(verbatim: "H").font(font(style))
            HelpButton(rowLabel: "Messages", text: "Help")
        }
        .helpLabelStyle(style)
        .frame(width: size.width, height: size.height)
        .background(background)
        .environment(\.colorScheme, scheme)
        let host = NSHostingView(rootView: row)
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        host.layoutSubtreeIfNeeded()
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        window.contentView = nil
        let bitmap = try #require(InkBitmap(rep))
        let all = CGRect(origin: .zero, size: size)
        let columns = InkScan.inkColumns(bitmap, all, Self.threshold)
        let first = try #require(columns.first), last = try #require(columns.last)
        // The clusters: split at the widest gap between ink columns.
        var split = first, gap = 0
        for (a, b) in zip(columns, columns.dropFirst()) where b - a > gap { gap = b - a; split = a }
        #expect(gap > 4, "the H and the glyph run together")
        let h = CGRect(x: CGFloat(first) / bitmap.scale, y: 0,
                       width: CGFloat(split + 1 - first) / bitmap.scale, height: size.height)
        let glyphStart = columns.first { $0 > split } ?? last
        let g = CGRect(x: CGFloat(glyphStart) / bitmap.scale, y: 0,
                       width: CGFloat(last + 1 - glyphStart) / bitmap.scale, height: size.height)
        // The canvas's corner is background; a rect's own corner may be ink.
        let hMid = try #require(InkScan.centreY(bitmap, in: h, threshold: Self.threshold, background: bitmap.pixels[0]))
        let gMid = try #require(InkScan.centreY(bitmap, in: g, threshold: Self.threshold, background: bitmap.pixels[0]))
        return (hMid, gMid)
    }

    /// Tertiary on black is faint: a low threshold still finds it, and the background is flat.
    private static let threshold = 16

    @Test(arguments: [HelpLabelStyle.body, .heading, .prose, .caption, .subheadline])
    func centredOnCaps(style: HelpLabelStyle) throws {
        for scheme in [ColorScheme.light, .dark] {
            let c = try centres(style, scheme: scheme)
            #expect(abs(c.glyph - c.h) <= 1, "\(style) \(scheme): glyph \(c.glyph), H \(c.h)")
        }
    }

    @Test func inkRowsFindsPaintedRows() {
        let white = InkBitmap.rgba(255, 255, 255, 255), black = InkBitmap.rgba(0, 0, 0, 255)
        var pixels = Array(repeating: white, count: 20 * 20)
        for y in 6..<10 { for x in 2..<4 { pixels[y * 20 + x] = black } }
        let bitmap = InkBitmap(width: 20, height: 20, scale: 2, pixels: pixels)
        let rect = CGRect(x: 0, y: 0, width: 10, height: 10)
        #expect(InkScan.inkRows(bitmap, in: rect, threshold: 48) == [6, 7, 8, 9])
        #expect(InkScan.centreY(bitmap, in: rect, threshold: 48) == 4)
    }
}
