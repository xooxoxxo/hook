import AppKit
import Testing
@testable import RelayCore

/// The count behind the Dock icon: regular from the first window, accessory after the last.
@Suite struct StandardWindowsTests {
    @Test func theFirstOpenAndTheLastCloseChangeThePolicy() {
        let a = NSObject(), b = NSObject()
        var windows = StandardWindows()
        #expect(windows.opened(ObjectIdentifier(a)) == .regular)
        #expect(windows.opened(ObjectIdentifier(b)) == nil)
        #expect(windows.closed(ObjectIdentifier(a)) == nil)
        #expect(windows.closed(ObjectIdentifier(b)) == .accessory)
        #expect(windows.isEmpty)
    }

    @Test func showingAnOpenWindowAgainOrClosingAnUnknownOneChangesNothing() {
        let a = NSObject(), b = NSObject()
        var windows = StandardWindows()
        #expect(windows.opened(ObjectIdentifier(a)) == .regular)
        #expect(windows.opened(ObjectIdentifier(a)) == nil)
        #expect(windows.closed(ObjectIdentifier(b)) == nil)
        #expect(windows.open.count == 1)
        #expect(windows.closed(ObjectIdentifier(a)) == .accessory)
        #expect(windows.closed(ObjectIdentifier(a)) == nil)
        // Reopened after the last close: regular again.
        #expect(windows.opened(ObjectIdentifier(a)) == .regular)
    }
}
