import AppKit
import SwiftUI
import Testing
@testable import RelayUIMac

@Suite @MainActor struct PanelFirstClickTests {
    @Test func inactivePanelAcceptsControlClick() throws {
        let host = PanelHostingView(rootView:
            QueueMenu(grouping: .constant(.project), filter: .constant(nil), projects: []))
        let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                             styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        #expect(!window.isKeyWindow)
        let event = try #require(NSEvent.mouseEvent(with: .leftMouseDown,
            location: NSPoint(x: 10, y: 10), modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 1,
            clickCount: 1, pressure: 1))
        #expect(host.acceptsFirstMouse(for: event))
    }
}
