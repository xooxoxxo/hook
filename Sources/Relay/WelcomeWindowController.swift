import AppKit
import RelayCore
import RelayUI
import SwiftUI

/// The first-run window "Welcome to Relay" (§4.9): shown for a missing or incomplete
/// config, and again from the menu's "Set Up Relay…" or the panel's Not set up state.
@MainActor final class WelcomeWindowController {
    private let window: NSWindow

    init(model: AppModel, onDone: @escaping @MainActor () -> Void) {
        let ref = WindowRef()
        let view = WelcomeView(
            model: model,
            onDone: { ref.window?.close(); onDone() },
            onQuit: { NSApp.terminate(nil) })
        let controller = NSHostingController(rootView: view)
        controller.sizingOptions = [.preferredContentSize]
        window = NSWindow(contentViewController: controller)
        window.title = "Welcome to Relay"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        ref.window = window
    }

    var isVisible: Bool { window.isVisible }

    func show() {
        if !window.isVisible { window.center() }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    func close() {
        window.close()
    }
}

/// Lets the SwiftUI buttons close the window that hosts them.
@MainActor private final class WindowRef {
    weak var window: NSWindow?
}
