import AppKit
import SwiftUI
import Testing
@testable import RelayUI

/// The label of a setup row lines up with its control's centre, so a tall control (the
/// shortcut recorder) doesn't leave the label at its top.
@Suite @MainActor struct SetupRowTests {
    /// The vertical centre, in points from the top, of the dark ink in `columns` of the view.
    private func inkCentre(_ view: some View, size: NSSize, columns: Range<Int>) throws -> CGFloat {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height).background(Color.white)
            .environment(\.colorScheme, .light))
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let scale = CGFloat(rep.pixelsHigh) / size.height
        var rows: [Int] = []
        for y in 0..<rep.pixelsHigh {
            for x in columns.lowerBound * Int(scale)..<min(columns.upperBound * Int(scale), rep.pixelsWide) {
                if let color = rep.colorAt(x: x, y: y), color.brightnessComponent < 0.5 {
                    rows.append(y)
                    break
                }
            }
        }
        let first = try #require(rows.first), last = try #require(rows.last)
        return CGFloat(first + last) / 2 / scale
    }

    @Test func theLabelSitsAtTheControlsCentre() throws {
        let height: CGFloat = 90
        let row = SetupRow("Shortcut", symbol: "keyboard") {
            Color.clear.frame(width: 40, height: height)
        }
        // The title's ink, left of the control.
        let centre = try inkCentre(row, size: NSSize(width: 320, height: height), columns: 30..<120)
        #expect(abs(centre - height / 2) < 4)
    }

    @Test func anErrorUnderTheControlDoesNotMoveTheLabel() throws {
        let height: CGFloat = 60
        let row = SetupRow("Shortcut", symbol: "keyboard", error: "Taken") {
            Color.clear.frame(width: 40, height: height)
        }
        let size = NSSize(width: 320, height: height + 60)
        let centre = try inkCentre(row.frame(maxHeight: .infinity, alignment: .top), size: size, columns: 30..<120)
        #expect(abs(centre - height / 2) < 4)
    }
}
