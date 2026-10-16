import CoreGraphics
import Testing
@testable import RelayUI

/// A 2× bitmap, white, `widthPt` × `heightPt` points.
private func canvas(_ widthPt: Int, _ heightPt: Int) -> InkBitmap {
    let white = InkBitmap.rgba(255, 255, 255, 255)
    return InkBitmap(width: widthPt * 2, height: heightPt * 2, scale: 2,
                     pixels: Array(repeating: white, count: widthPt * 2 * heightPt * 2))
}

/// Paints black pixels over the half-open pixel ranges.
private func paint(_ bitmap: InkBitmap, columns: Range<Int>, rows: Range<Int>) -> InkBitmap {
    var pixels = bitmap.pixels
    let black = InkBitmap.rgba(0, 0, 0, 255)
    for y in rows { for x in columns { pixels[y * bitmap.width + x] = black } }
    return InkBitmap(width: bitmap.width, height: bitmap.height, scale: bitmap.scale, pixels: pixels)
}

private func probe(_ role: ProbeRole, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, group: String = "") -> ProbeFrame {
    ProbeFrame(role: role, group: group, frame: CGRect(x: x, y: y, width: w, height: h))
}

@Suite struct AlignmentCheckTests {
    /// Ink in pixel columns 32..<40 of a 2× bitmap: 16 pt to 20 pt.
    private let ink = paint(canvas(50, 10), columns: 32..<40, rows: 0..<20)

    @Test func inkIsFoundInPoints() {
        let rect = CGRect(x: 0, y: 0, width: 50, height: 10)
        #expect(InkScan.firstInkX(ink, in: rect, threshold: 48) == 16)
        #expect(InkScan.lastInkX(ink, in: rect, threshold: 48) == 20)
        #expect(InkScan.centreX(ink, in: rect, threshold: 48) == 18)
        #expect(InkScan.firstInkX(ink, in: CGRect(x: 25, y: 0, width: 20, height: 10), threshold: 48) == nil)
    }

    @Test func leadingPassesWithinToleranceAndFailsOffByTwo() {
        let probes = [probe(.gutterText, 0, 0, 50, 10)]
        #expect(AlignmentCheck.verify(probes, bitmap: ink, rules: [.leading(.gutterText, x: 16, tolerance: 1)]).isEmpty)
        #expect(AlignmentCheck.verify(probes, bitmap: ink, rules: [.leading(.gutterText, x: 17, tolerance: 1)]).isEmpty)
        let failures = AlignmentCheck.verify(probes, bitmap: ink, rules: [.leading(.gutterText, x: 18, tolerance: 1)])
        #expect(failures.count == 1)
        #expect(failures.first?.detail.contains("16.0") == true)
    }

    @Test func trailingAndCentre() {
        let probes = [probe(.trailingEdge, 0, 0, 50, 10)]
        #expect(AlignmentCheck.verify(probes, bitmap: ink, rules: [.trailing(.trailingEdge, x: 20, tolerance: 2)]).isEmpty)
        #expect(AlignmentCheck.verify(probes, bitmap: ink, rules: [.trailing(.trailingEdge, x: 24, tolerance: 2)]).count == 1)
        let two = [probe(.topMarker, 0, 0, 50, 5), probe(.topMarker, 0, 5, 50, 5)]
        #expect(AlignmentCheck.verify(two, bitmap: ink, rules: [.sameCentre(.topMarker, tolerance: 1)]).isEmpty)
        #expect(AlignmentCheck.verify(two, bitmap: ink, rules: [.sameLeading(.topMarker, tolerance: 1)]).isEmpty)
    }

    @Test func anEmptyRectReportsNoInk() {
        let failures = AlignmentCheck.verify([probe(.gutterText, 25, 0, 20, 10)], bitmap: ink,
                                             rules: [.leading(.gutterText, x: 16, tolerance: 1)])
        #expect(failures.count == 1)
        #expect(failures.first?.detail.contains("no ink") == true)
    }

    @Test func aRuleWithoutProbesFails() {
        let failures = AlignmentCheck.verify([], bitmap: ink, rules: [.sameCentre(.subMarker, tolerance: 1)])
        #expect(failures.first?.detail == "no subMarker probe")
    }

    @Test func sameLeadingFailsWhenOneProbeIsOffset() {
        let offset = paint(paint(canvas(50, 10), columns: 32..<40, rows: 0..<10), columns: 40..<48, rows: 10..<20)
        let probes = [probe(.subMarker, 0, 0, 50, 5), probe(.subMarker, 0, 5, 50, 5)]
        #expect(AlignmentCheck.verify(probes, bitmap: offset, rules: [.sameLeading(.subMarker, tolerance: 1)]).count == 1)
    }

    @Test func trailingIsComparedPerGroup() {
        // Rows 0-4 pt end at 20 pt; rows 5-9 pt end at 24 pt.
        let bitmap = paint(paint(canvas(50, 10), columns: 30..<40, rows: 0..<10), columns: 30..<48, rows: 10..<20)
        let probes = [
            probe(.settingsTrailing, 0, 0, 50, 2.5, group: "Shortcut"), probe(.settingsTrailing, 0, 2.5, 50, 2.5, group: "Shortcut"),
            probe(.settingsTrailing, 0, 5, 50, 2.5, group: "Presence"), probe(.settingsTrailing, 0, 7.5, 50, 2.5, group: "Presence"),
        ]
        #expect(AlignmentCheck.verify(probes, bitmap: bitmap, rules: [.sameTrailingPerGroup(.settingsTrailing, tolerance: 1)]).isEmpty)
        let mixed = [probes[0], ProbeFrame(role: .settingsTrailing, group: "Shortcut", frame: probes[2].frame)]
        #expect(AlignmentCheck.verify(mixed, bitmap: bitmap, rules: [.sameTrailingPerGroup(.settingsTrailing, tolerance: 1)]).count == 1)
    }

    @Test func aProbeCutOffByTheBottomEdgeIsSkipped() {
        // Ink only in the top 5 pt; the second row starts at 8 pt and hangs 14 pt past the 10 pt edge,
        // so its visible strip is blank (a List row cut off at the bottom of the capture).
        let top = paint(canvas(50, 10), columns: 32..<40, rows: 0..<10)
        let rows = [probe(.gutterText, 0, 0, 50, 5), probe(.gutterText, 0, 8, 50, 16)]
        #expect(AlignmentCheck.verify(rows, bitmap: top, rules: [.leading(.gutterText, x: 16, tolerance: 1)]).isEmpty)
        // The skipped row doesn't hide a real misalignment in the rows that are inside.
        #expect(AlignmentCheck.verify(rows, bitmap: top, rules: [.leading(.gutterText, x: 18, tolerance: 1)]).count == 1)
        // A probe off the top or the sides counts as clipped too; rounding within half a point doesn't.
        #expect(AlignmentCheck.verify([probe(.gutterText, 0, -3, 50, 5), probe(.gutterText, 0, 0, 50.4, 5)],
                                      bitmap: top, rules: [.leading(.gutterText, x: 16, tolerance: 1)]).isEmpty)
    }

    @Test func aRuleWhoseProbesAreAllClippedFails() {
        let failures = AlignmentCheck.verify([probe(.gutterText, 0, 8, 50, 16)], bitmap: ink,
                                             rules: [.leading(.gutterText, x: 16, tolerance: 1)])
        #expect(failures.map(\.detail) == ["no gutterText probe inside the capture (1 clipped)"])
    }

    @Test func failuresDescribeTheRule() {
        let failure = AlignmentFailure(rule: .leading(.gutterText, x: 16, tolerance: 1), detail: "no ink")
        #expect(failure.description == "leading(gutterText, x: 16.0, tolerance: 1.0): no ink")
    }
}
