import AppKit
import SwiftUI
import RelayCore

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

/// Re-docks the panel after display changes, sleep and wake, and Space
/// switches. Bursts (a monitor reconnecting posts several) are coalesced.
@MainActor final class PanelDocker: NSObject {
    static let debounce: Duration = .milliseconds(250)
    /// Displays reconnect a while after a wake, so wakes re-dock once more.
    static let wakeRetry: Duration = .seconds(1)

    private let redock: @MainActor () -> Void
    private var pending: Task<Void, Never>?
    private var retry: Task<Void, Never>?

    init(redock: @escaping @MainActor () -> Void) {
        self.redock = redock
        super.init()
        NotificationCenter.default.addObserver(
            self, selector: #selector(changed), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(self, selector: #selector(woke), name: NSWorkspace.didWakeNotification, object: nil)
        workspace.addObserver(self, selector: #selector(woke), name: NSWorkspace.screensDidWakeNotification, object: nil)
        workspace.addObserver(
            self, selector: #selector(changed), name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
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

/// Drag the panel by its header; on release it snaps to the nearest edge of
/// the display under the pointer and pins there. Sits behind the header
/// content, so the header's buttons still get their clicks.
struct PanelDragHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> PanelDragView { PanelDragView() }
    func updateNSView(_ nsView: PanelDragView, context: Context) {}
}

final class PanelDragView: NSView {
    /// Less movement than this, in points, is a click and does nothing.
    static let clickSlop: CGFloat = 3

    private var start: NSPoint?
    private var startOrigin: NSPoint = .zero
    private var dragging = false

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    override func mouseDown(with event: NSEvent) {
        start = NSEvent.mouseLocation
        startOrigin = window?.frame.origin ?? .zero
        dragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start, let window else { return }
        let now = NSEvent.mouseLocation
        let dx = now.x - start.x, dy = now.y - start.y
        if !dragging {
            guard max(abs(dx), abs(dy)) >= Self.clickSlop else { return }
            dragging = true
            NSCursor.closedHand.push()
        }
        window.setFrameOrigin(NSPoint(x: startOrigin.x + dx, y: startOrigin.y + dy))
    }

    override func mouseUp(with event: NSEvent) {
        defer { start = nil }
        guard dragging else { return }
        dragging = false
        NSCursor.pop()
        window?.invalidateCursorRects(for: self)
        (window as? SidePanel)?.pin(at: NSEvent.mouseLocation)
    }
}
