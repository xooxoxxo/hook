import AppKit
import RelayCore

/// Hook is a menu-bar app (`.accessory`): no Dock icon, not in ⌘-Tab, and ⌘-` has no
/// windows of Hook's to cycle. While an ordinary window is open (a document viewer,
/// Settings) it becomes a regular app, so ⌘-Tab and ⌘-` bring that window back; when
/// the last one closes it goes back to the menu bar only.
///
/// A window registers with `track(_:)` each time it is shown; its close is noticed on
/// its own. The panel never registers: it stays a non-activating panel either way.
@MainActor public final class AppPresence {
    public static let shared = AppPresence()

    private var windows = StandardWindows()
    private var observers: [ObjectIdentifier: NSObjectProtocol] = [:]
    /// Waits for Hook to stop being the active app before it goes back to `.accessory`.
    private var resignObserver: NSObjectProtocol?
    /// The policy last applied is `.regular` (a deferred switch back may still be waiting).
    private var isRegular = false
    /// Sets the policy (the gallery and the tests replace it).
    var apply: (NSApplication.ActivationPolicy) -> Void = { policy in
        _ = NSApp.setActivationPolicy(policy)
    }
    /// Whether Hook is the active app (the tests replace it).
    var isActive: () -> Bool = { NSApp.isActive }

    init() {}

    /// The number of tracked windows open.
    public var count: Int { windows.open.count }

    /// `window` is shown: counted until it closes. Calling it again for an open window does nothing.
    public func track(_ window: NSWindow) {
        let id = ObjectIdentifier(window)
        guard observers[id] == nil else { return }
        observers[id] = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.closed(id) }
        }
        opened(id)
    }

    /// A window opened, by identity (for a window `track` doesn't fit).
    public func opened(_ id: ObjectIdentifier) {
        guard let change = windows.opened(id) else { return }
        cancelPendingAccessory()
        if change == .regular, !isRegular { setPolicy(.regular) }
    }

    /// A window closed, by identity.
    public func closed(_ id: ObjectIdentifier) {
        if let observer = observers.removeValue(forKey: id) { NotificationCenter.default.removeObserver(observer) }
        guard windows.closed(id) == .accessory else { return }
        // While Hook is the active app (the owner just pressed ⌘W), switching now could hand
        // the focus to another app under the owner's hands: wait until Hook resigns active.
        guard isActive() else { return setPolicy(.accessory) }
        cancelPendingAccessory()
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.resigned() }
        }
    }

    /// Hook stopped being active: go back to the menu bar if nothing opened meanwhile.
    func resigned() {
        cancelPendingAccessory()
        if windows.isEmpty { setPolicy(.accessory) }
    }

    private func setPolicy(_ policy: NSApplication.ActivationPolicy) {
        isRegular = policy == .regular
        apply(policy)
    }

    private func cancelPendingAccessory() {
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
    }
}
