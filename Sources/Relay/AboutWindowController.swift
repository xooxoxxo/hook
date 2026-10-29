import AppKit
import RelayUI
import SwiftUI

/// The About window, from the menu's "About Hook". It replaces the stock About panel so it
/// can hold Run Setup Again…, which closes it and opens the setup window.
@MainActor final class AboutWindowController: NSObject {
    private let window: NSWindow

    init(onRunSetup: @escaping @MainActor () -> Void) {
        let ref = AboutWindowRef()
        let info = Bundle.main.infoDictionary ?? [:]
        let view = AboutView(
            version: info["CFBundleShortVersionString"] as? String ?? "—",
            build: info["CFBundleVersion"] as? String,
            onRunSetup: { ref.window?.close(); onRunSetup() })
        let controller = NSHostingController(rootView: view)
        controller.sizingOptions = [.preferredContentSize]
        window = NSWindow(contentViewController: controller)
        window.title = "About Hook"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        super.init()
        ref.window = window
    }

    func show() {
        if !window.isVisible { window.center() }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }
}

/// Lets the SwiftUI button close the window that hosts it.
@MainActor private final class AboutWindowRef {
    weak var window: NSWindow?
}
