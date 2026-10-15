import AppKit
import RelayCore

/// Non-activating floating panel docked to the left or right edge of the main
/// screen, on a sidebar-material background. No window buttons;
/// the content starts at the top edge.
@MainActor final class SidePanel: NSPanel {
    static let width: CGFloat = 380

    /// The edge from config `sidebarEdge`, set through `dock(edge:)`.
    private(set) var edge: SidebarEdge = .right
    /// Esc goes to the content first: true means it was used (a detail went back
    /// to the list). Otherwise the panel hides.
    var onEscape: (@MainActor () -> Bool)?

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
        // Docked, not a document window: no traffic lights and no dragging.
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
    }

    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        if onEscape?() == true { return }
        orderOut(nil)
    }

    /// Full height of the visible frame, 380 pt wide, on `edge`.
    func dock(edge: SidebarEdge) {
        self.edge = edge
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let frame = screen.visibleFrame
        let x = edge == .left ? frame.minX : frame.maxX - Self.width
        setFrame(NSRect(x: x, y: frame.minY, width: Self.width, height: frame.height), display: true)
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
