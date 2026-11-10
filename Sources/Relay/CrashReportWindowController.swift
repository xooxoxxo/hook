import AppKit
import RelayCore
import RelayUI
import SwiftUI

/// Send a Crash Report in its own window, built like Settings: a stock titled, closable
/// window, centred when it opens, that brings Hook forward. It hosts `CrashReportView` on
/// the Store. The Store opens it (Review… on the crash bar) through `show()` and closes it
/// through `close()` whenever the report ends: sent, cancelled or dropped with Not Now.
/// Closing the window yourself (its close button, ⌘W, Esc) is Cancel: the bar stays.
@MainActor final class CrashReportWindowController: NSObject, NSWindowDelegate {
    /// Lets other code pick this window's notifications out of every window's.
    static let windowID = NSUserInterfaceItemIdentifier("relay.crashReport")

    private let store: Store
    private let window: CrashReportWindow
    /// True while the window is closing, so the Store's close doesn't close it again.
    private var closing = false

    /// After the window comes on screen, and after it has closed: the place to switch the
    /// activation policy while a standard window is open.
    var onOpen: (@MainActor () -> Void)?
    var onClose: (@MainActor () -> Void)?

    var isOpen: Bool { window.isVisible }

    init(store: Store) {
        self.store = store
        let controller = NSHostingController(rootView: CrashReportView(model: store))
        controller.sizingOptions = [.preferredContentSize]
        window = CrashReportWindow(contentViewController: controller)
        super.init()
        window.title = "Crash Report"
        window.styleMask = [.titled, .closable]
        window.identifier = Self.windowID
        window.isReleasedWhenClosed = false
        window.delegate = self
    }

    /// Opens the window, or brings the open one forward.
    func show() {
        let opening = !window.isVisible
        if opening { window.center() }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        if opening { onOpen?() }
    }

    /// The report ended in the Store.
    func close() {
        guard !closing, window.isVisible else { return }
        window.close()
    }

    func windowWillClose(_ notification: Notification) {
        closing = true
        // A no-op when the Store ended the report itself.
        store.closeCrashSheet()
        closing = false
        onClose?()
    }
}

/// ⌘W closes, with no File menu holding it.
final class CrashReportWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers == .command, event.charactersIgnoringModifiers == "w" {
            performClose(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
