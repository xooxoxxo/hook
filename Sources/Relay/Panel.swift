import AppKit
import RelayCore

/// Non-activating floating panel docked to the left or right edge of its pinned
/// display (config `sidebarDisplay`, else the main display), on a
/// sidebar-material background. No window buttons; the content starts at the
/// top edge. It re-docks after display changes, wakes and Space switches.
@MainActor final class SidePanel: NSPanel {
    static let width: CGFloat = 380

    /// The edge from config `sidebarEdge`, set through `dock(edge:)`.
    private(set) var edge: SidebarEdge = .right
    /// Esc goes to the content first: true means it was used (a detail went back
    /// to the list). Otherwise the panel hides.
    var onEscape: (@MainActor () -> Bool)?
    /// Reads `sidebarDisplay` and saves a pin from a header drag; set by `connect(_:)`.
    private weak var model: AppModel?
    private var docker: PanelDocker?

    init(content: NSView) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 600),
            styleMask: [.nonactivatingPanel, .titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false)
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        // Docked, not a document window: no traffic lights, and AppKit doesn't
        // move it. A header drag (PanelDragHandle) moves it and then re-docks.
        // `.titled` stays for the rounded corners, shadow and key-window behaviour.
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            standardWindowButton(kind)?.isHidden = true
        }
        isMovable = false

        let background = NSVisualEffectView()
        background.material = .sidebar
        background.blendingMode = .behindWindow
        background.state = .active
        content.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            content.topAnchor.constraint(equalTo: background.topAnchor),
            content.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])
        contentView = background
        dock(edge: .right)
        docker = PanelDocker { [weak self] in
            guard let self else { return }
            self.dock(edge: self.edge)
        }
    }

    /// Docks to the model's pinned display, and saves the pin a header drag picks.
    func connect(_ model: AppModel) {
        self.model = model
        dock(edge: edge)
    }

    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        if onEscape?() == true { return }
        orderOut(nil)
    }

    /// Full height of the pinned display's visible frame, 380 pt wide, on `edge`.
    /// A pinned display that isn't connected falls back to the main display;
    /// the pin is kept, so the panel goes back when it reconnects. Runs while
    /// hidden too, so the next show is already in place.
    func dock(edge: SidebarEdge) {
        self.edge = edge
        guard let screen = DockGeometry.target(screens: NSScreen.dockScreens, pinned: model?.config?.sidebarDisplay)
        else { return }
        let frame = DockGeometry.frame(edge: edge, on: screen, width: Self.width)
        if frame != self.frame { setFrame(frame, display: true) }
    }

    /// The end of a header drag at `point` (screen coordinates): pins the panel
    /// to that display's nearer edge, saves `sidebarEdge` and `sidebarDisplay`,
    /// and slides it into place (no slide with Reduce Motion).
    func pin(at point: NSPoint) {
        let screens = NSScreen.dockScreens
        guard let snap = DockGeometry.snap(point: point, screens: screens),
              let screen = screens.first(where: { $0.id == snap.screenID }) else {
            dock(edge: edge)
            return
        }
        edge = snap.edge
        model?.save(set: ["sidebarEdge": snap.edge.rawValue, "sidebarDisplay": snap.screenID])
        let animate = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        setFrame(DockGeometry.frame(edge: snap.edge, on: screen, width: Self.width), display: true, animate: animate)
    }

    /// Brings the panel in. `focus` false (slide-in for "now" asks) leaves the
    /// frontmost app's focus alone; either way it stays until hidden.
    func present(focus: Bool) {
        dock(edge: edge)
        orderFrontRegardless()
        if focus { makeKey() }
    }

    func show() {
        present(focus: true)
    }

    func toggle() {
        if isVisible { orderOut(nil) } else { present(focus: true) }
    }
}
