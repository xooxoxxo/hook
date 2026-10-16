import AppKit
import RelayCore
import SwiftUI
import Testing
@testable import RelayUI

/// Rule A3: QueueMenu's click region is the 28 pt square. A `.borderlessButton` menu
/// becomes a glyph-sized NSPopUpButton (measured 26 × 15 pt) and the padding around it
/// passes clicks to the header's drag handle, so the label must be drawn by SwiftUI.
@Suite @MainActor struct QueueMenuHitAreaTests {
    private func host() -> NSHostingView<QueueMenu> {
        let menu = QueueMenu(grouping: .constant(.project), filter: .constant(nil),
                             projects: [MenuProject(name: "Acme", open: 1)])
        let host = NSHostingView(rootView: menu)
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        return host
    }

    @Test func labelIsHitSized() {
        let size = host().fittingSize
        #expect(size.width >= DS.Metric.hit)
        #expect(size.height >= DS.Metric.hit)
    }

    @Test func noGlyphSizedAppKitControl() {
        let small = Self.controls(in: host()).filter {
            $0.frame.width < DS.Metric.hit || $0.frame.height < DS.Metric.hit
        }
        #expect(small.isEmpty, "controls smaller than the hit area: \(small.map { "\(type(of: $0)) \($0.frame.size)" })")
    }

    static func controls(in view: NSView) -> [NSControl] {
        view.subviews.flatMap { sub -> [NSControl] in
            ((sub as? NSControl).map { [$0] } ?? []) + controls(in: sub)
        }
    }
}
