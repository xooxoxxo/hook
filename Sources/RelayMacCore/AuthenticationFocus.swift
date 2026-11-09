import AppKit

/// Return only the window that requested authentication, never a window closed meanwhile.
/// This owns no credentials and changes neither authentication nor Keychain policy.
@MainActor final class AuthenticationFocus {
    private var cancelled = false
    private var finished = false
    private let canRestore: @MainActor () -> Bool
    private let restore: @MainActor () -> Void
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    static func capture() -> AuthenticationFocus {
        weak var window = NSApp.keyWindow ?? NSApp.mainWindow
        let beganActive = NSApp.isActive
        return AuthenticationFocus(window: window, canRestore: {
            beganActive && !NSApp.isHidden && window?.isVisible == true && window?.isMiniaturized == false
                && (NSApp.keyWindow == nil || NSApp.keyWindow === window)
        }, restore: {
            NSApp.activate()
            window?.makeKeyAndOrderFront(nil)
        })
    }

    init(window: NSWindow?, center: NotificationCenter = .default,
         workspace: NotificationCenter = NSWorkspace.shared.notificationCenter,
         distributed: NotificationCenter = DistributedNotificationCenter.default(),
         canRestore: @escaping @MainActor () -> Bool,
         restore: @escaping @MainActor () -> Void) {
        self.canRestore = canRestore
        self.restore = restore
        if let window { watch(center, NSWindow.willCloseNotification, object: window) }
        watch(center, NSApplication.didHideNotification)
        watch(workspace, NSWorkspace.sessionDidResignActiveNotification)
        watch(workspace, NSWorkspace.screensDidSleepNotification)
        watch(distributed, Notification.Name("com.apple.screenIsLocked"))
        let token = workspace.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                          object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let otherRegularApp = app.processIdentifier != ProcessInfo.processInfo.processIdentifier
                && app.activationPolicy == .regular
            MainActor.assumeIsolated { self?.activatedOtherApplication(isRegular: otherRegularApp) }
        }
        observers.append((workspace, token))
    }

    // Authentication helpers can activate transient accessory UI. An ordinary app switch
    // means the owner moved on, even if Hook becomes active again before the reply arrives.
    func activatedOtherApplication(isRegular: Bool) {
        if isRegular { cancelled = true }
    }

    func finish(confirmed: Bool) {
        guard !finished else { return }
        finished = true
        for (center, observer) in observers { center.removeObserver(observer) }
        observers.removeAll()
        if confirmed && !cancelled && canRestore() { restore() }
    }

    private func watch(_ center: NotificationCenter, _ name: Notification.Name, object: AnyObject? = nil) {
        let token = center.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.cancelled = true }
        }
        observers.append((center, token))
    }
}
