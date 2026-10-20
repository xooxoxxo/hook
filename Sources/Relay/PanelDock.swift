import AppKit
import RelayCore
import RelayUI

extension NSScreen {
    /// The display's UUID string, from its CGDirectDisplayID; nil if AppKit
    /// doesn't report one.
    var displayUUID: String? {
        guard let number = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue() else {
            return nil
        }
        return CFUUIDCreateString(nil, uuid) as String
    }

    /// Every connected display as docking sees it. The first one has the menu bar.
    static var dockScreens: [DockScreen] {
        screens.enumerated().compactMap { index, screen in
            guard let id = screen.displayUUID else { return nil }
            return DockScreen(id: id, frame: screen.frame, visibleFrame: screen.visibleFrame, isPrimary: index == 0)
        }
    }
}

/// Re-docks the panel after display changes, the panel landing on another display,
/// sleep and wake, and Space switches. Bursts (a monitor reconnecting posts several)
/// are coalesced.
@MainActor final class PanelDocker: NSObject {
    static let debounce: Duration = .seconds(DS.Motion.redockDebounce)
    /// Displays reconnect a while after a wake, so wakes re-dock once more.
    static let wakeRetry: Duration = .seconds(DS.Motion.wakeRecheck)

    private let redock: @MainActor () -> Void
    private var pending: Task<Void, Never>?
    private var retry: Task<Void, Never>?

    init(window: NSWindow, redock: @escaping @MainActor () -> Void) {
        self.redock = redock
        super.init()
        NotificationCenter.default.addObserver(
            self, selector: #selector(changed), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(self, selector: #selector(woke), name: NSWorkspace.didWakeNotification, object: nil)
        workspace.addObserver(self, selector: #selector(woke), name: NSWorkspace.screensDidWakeNotification, object: nil)
        workspace.addObserver(
            self, selector: #selector(changed), name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        // The panel itself landed on another display (a drag, or AppKit moving it).
        NotificationCenter.default.addObserver(
            self, selector: #selector(changed), name: NSWindow.didChangeScreenNotification, object: window)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    @objc private func changed() {
        schedule()
    }

    @objc private func woke() {
        schedule()
        retry?.cancel()
        retry = Task { [weak self] in
            try? await Task.sleep(for: Self.wakeRetry)
            guard !Task.isCancelled else { return }
            self?.schedule()
        }
    }

    /// Re-docks once, 0.25 s after the last trigger in a burst.
    private func schedule() {
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: Self.debounce)
            guard !Task.isCancelled else { return }
            self?.redock()
        }
    }
}
