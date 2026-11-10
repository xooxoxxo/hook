import AppKit
import Testing
@testable import RelayUI

/// Refuses the first mouse, as the hosting view SwiftUI's List makes for each queue row
/// does. It records whether its window was key when the press reached it.
private final class RowLikeView: NSView {
    var presses: [Bool] = []
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { false }
    override func mouseDown(with event: NSEvent) { presses.append(window?.isKeyWindow == true) }
}

private final class KeyableFirstClickPanel: FirstClickPanel {
    override var canBecomeKey: Bool { true }
}

private final class KeyablePlainPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Whether this login session lets a window become key; a locked screen doesn't.
@MainActor private enum KeySession {
    static func available() -> Bool {
        _ = NSApplication.shared
        let panel = KeyablePlainPanel(contentRect: NSRect(x: -20000, y: -20000, width: DS.Metric.panelWidth,
                                                          height: DS.Metric.panelWidth),
                                      styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.orderFrontRegardless()
        panel.makeKey()
        defer { panel.orderOut(nil) }
        return panel.isKeyWindow
    }
}

/// The first click on a panel that isn't key reaches the view under it. The panel is built
/// like the side panel (borderless, non-activating) and kept off every screen. The press goes
/// straight to the window: a posted NSEvent ends the test process early.
@Suite(.serialized, .enabled("needs a session where a window can become key (not a locked screen)") {
    await KeySession.available()
})
@MainActor struct PanelFirstClickTests {
    private static let frame = NSRect(x: -20000, y: -20000, width: DS.Metric.panelWidth, height: DS.Metric.panelWidth)
    private static let style: NSWindow.StyleMask = [.nonactivatingPanel, .borderless, .fullSizeContentView]

    private func press(_ panel: NSPanel) throws -> RowLikeView {
        _ = NSApplication.shared
        let row = RowLikeView(frame: NSRect(origin: .zero, size: Self.frame.size))
        panel.isReleasedWhenClosed = false
        panel.contentView = row
        panel.orderFrontRegardless()
        defer {
            panel.orderOut(nil)
            panel.contentView = nil
        }
        #expect(!panel.isKeyWindow)
        let down = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 10, y: 10),
            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
            context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        panel.sendEvent(down)
        #expect(panel.isKeyWindow)
        return row
    }

    @Test func theFirstPressReachesARowThatRefusesTheFirstMouse() throws {
        let row = try press(KeyableFirstClickPanel(contentRect: Self.frame, styleMask: Self.style,
                                                   backing: .buffered, defer: false))
        #expect(row.presses == [true])
    }

    /// Why: a plain panel uses that press only to become key, so the row never sees it.
    @Test func aPlainPanelSwallowsIt() throws {
        let row = try press(KeyablePlainPanel(contentRect: Self.frame, styleMask: Self.style,
                                              backing: .buffered, defer: false))
        #expect(row.presses.isEmpty)
    }
}

@Suite struct FirstClickRuleTests {
    @Test func onlyALeftPressOnAPanelThatIsNotKeyMakesItKeyFirst() {
        #expect(FirstClick.makesKeyFirst(.leftMouseDown, isKey: false, canBecomeKey: true, sheetOpen: false))
        #expect(!FirstClick.makesKeyFirst(.leftMouseDown, isKey: true, canBecomeKey: true, sheetOpen: false))
        #expect(!FirstClick.makesKeyFirst(.leftMouseDown, isKey: false, canBecomeKey: false, sheetOpen: false))
        #expect(!FirstClick.makesKeyFirst(.leftMouseDown, isKey: false, canBecomeKey: true, sheetOpen: true))
        for type: NSEvent.EventType in [.leftMouseUp, .rightMouseDown, .otherMouseDown, .mouseMoved, .scrollWheel, .keyDown] {
            #expect(!FirstClick.makesKeyFirst(type, isKey: false, canBecomeKey: true, sheetOpen: false))
        }
    }
}
