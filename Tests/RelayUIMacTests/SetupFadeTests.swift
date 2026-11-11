import AppKit
import SwiftUI
import Testing
@testable import RelayUI
@testable import RelayUIMac

/// A Welcome form page that scrolls under the footer fades out over its last
/// `DS.Metric.setupFade` points, so the row cut by the footer reads as scrolling, not clipped.
@Suite @MainActor struct SetupFadeTests {
    /// The brightness at `y` points from the top, in the middle column of a white-backed render.
    private func brightness(_ view: some View, size: NSSize, at ys: [CGFloat]) throws -> [CGFloat] {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height)
            .background(Color.white).environment(\.colorScheme, .light))
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let scale = CGFloat(rep.pixelsHigh) / size.height
        return ys.map { y in
            rep.colorAt(x: Int(size.width / 2 * scale), y: Int(y * scale))?.brightnessComponent ?? -1
        }
    }

    @Test func theLastPointsFadeToTheBackground() throws {
        let height: CGFloat = 120
        let page = Color.black.setupScrollEnd()
        let end = height - DS.Space.setupFormEnd
        let values = try brightness(page, size: NSSize(width: 100, height: height),
                                    at: [end - DS.Metric.setupFade - 4, end - DS.Metric.setupFade / 2, end - 1, height - 2])
        #expect(values[0] < 0.1, "\(values)")               // above the fade: untouched
        #expect(values[1] > 0.3 && values[1] < 0.7, "\(values)")
        #expect(values[2] > 0.9, "\(values)")               // the page's last point: the background
        #expect(values[3] > 0.9, "\(values)")               // the gap above the footer
    }
}
