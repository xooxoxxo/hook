import AppKit
import RelayCore
import RelayUI
import SwiftUI

/// The setup window: shown at launch for a missing or incomplete config or one that holds
/// `onboarding: "pending"`, and again from the menu's "Set Up Hook…", About's "Run Setup
/// Again…" or the panel's Not set up state. Closing it, by Open Hook or the close button, ends setup.
@MainActor final class WelcomeWindowController: NSObject, NSWindowDelegate {
    private let window: NSWindow
    private let onClose: @MainActor () -> Void

    /// `onDone`: Open Hook was pressed. `onClose`: the window closed, either way.
    init(model: AppModel, onDone: @escaping @MainActor () -> Void, onClose: @escaping @MainActor () -> Void) {
        let ref = WindowRef()
        let view = WelcomeView(model: model, onDone: { ref.window?.close(); onDone() })
        let controller = NSHostingController(rootView: view)
        controller.sizingOptions = [.preferredContentSize]
        window = NSWindow(contentViewController: controller)
        window.title = "Set Up Hook"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        self.onClose = onClose
        super.init()
        window.delegate = self
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

    nonisolated func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated { onClose() }
    }
}

/// Lets the SwiftUI buttons close the window that hosts them.
@MainActor private final class WindowRef {
    weak var window: NSWindow?
}
