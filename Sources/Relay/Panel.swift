import AppKit
import RelayCore
import RelayUI

/// Non-activating, borderless floating panel docked flush to the left or right edge of its pinned display (config `sidebarDisplay`, else the main display), on a sidebar-material background. Square corners; no window buttons; the content starts at the top edge. It re-docks after display changes, wakes and Space switches.
@MainActor final class SidePanel: NSPanel {
    static var width: CGFloat { DS.Metric.panelWidth }

    /// The edge from config `sidebarEdge`, set through `dock(edge:)`.
    private(set) var edge: SidebarEdge = .right
    /// Esc goes to the content first: true means it was used (a detail went back
    /// to the list). Otherwise the panel hides.
    var onEscape: (@MainActor () -> Bool)?
    /// The panel-wide keys (design §4.12); AppDelegate sets it once the panel hosts PanelRoot.
    var keyRouter: PanelKeyRouter?
    /// Reads `sidebarDisplay` and saves a pin from a header drag; set by `connect(_:)`.
    private weak var model: AppModel?
    private var docker: PanelDocker?
    /// True from the first move of a header drag until `pin(at:)` or a hide.
    /// Re-docks wait meanwhile, so the panel stays under the pointer.
    private(set) var isDragging = false

    /// Bumped by every show and hide, so a fade-out that finishes after a new show
    /// doesn't order the panel out.
    private var fadeToken = 0

    /// True while a hide's fade-out runs. The panel is still ordered in then, but it
    /// is on its way out, so the toggle rule and a "now" ask treat it as hidden.
    private(set) var isFadingOut = false

    /// On screen and staying there: visible and not fading out.
    var isShown: Bool { isVisible && !isFadingOut }

    /// Where the panel belongs now: the pinned (or main) display's docked frame on `edge`.
    var targetFrame: CGRect? {
        guard let screen = DockGeometry.target(screens: NSScreen.dockScreens, pinned: model?.config?.sidebarDisplay)
        else { return nil }
        return DockGeometry.frame(edge: edge, on: screen, width: Self.width)
    }

    init(content: NSView) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: Self.width),
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false)
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        // Relay moves the panel itself: the header drag and PanelDock.
        isMovable = false
        // Never shown (no title bar), but it names the window for VoiceOver and the Window menu.
        title = "Relay"
        setAccessibilityLabel("Relay")

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
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        if let keyRouter {
            if !keyRouter.route(.escape, event: nil, in: self) { hide(animated: true) }
            return
        }
        if onEscape?() == true { return }
        hide(animated: true)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if let keyRouter, keyRouter.handle(event, in: self) { return true }
        return super.performKeyEquivalent(with: event)
    }

    /// Full height of the pinned display's visible frame, 380 pt wide, on `edge`.
    /// A pinned display that isn't connected falls back to the main display;
    /// the pin is kept, so the panel goes back when it reconnects. Runs while
    /// hidden too, so the next show is already in place.
    func dock(edge: SidebarEdge) {
        self.edge = edge
        guard !isDragging else { return }
        guard let screen = DockGeometry.target(screens: NSScreen.dockScreens, pinned: model?.config?.sidebarDisplay)
        else { return }
        let frame = DockGeometry.frame(edge: edge, on: screen, width: Self.width)
        if frame != self.frame { setFrame(frame, display: true) }
    }

    /// A header drag moved the panel; holds off re-docks until it ends.
    func beginDrag() {
        isDragging = true
    }

    /// The end of a header drag at `point` (screen coordinates): pins the panel
    /// to that display's nearer edge, saves `sidebarEdge` and `sidebarDisplay`,
    /// and slides it into place (no slide with Reduce Motion). The slide goes
    /// where the reloaded config says, so a save that fails, or a reload that
    /// keeps the last good config, slides the panel back to its old spot.
    func pin(at point: NSPoint) {
        let screens = NSScreen.dockScreens
        let snap = DockGeometry.snap(point: point, screens: screens)
        if let snap, let model {
            model.save(set: ["sidebarEdge": snap.edge.rawValue, "sidebarDisplay": snap.screenID])
        }
        isDragging = false
        let pinned: (edge: SidebarEdge, display: String?)
        if let model {
            pinned = (model.config?.sidebarEdge ?? edge, model.config?.sidebarDisplay)
        } else {
            pinned = (snap?.edge ?? edge, snap?.screenID)
        }
        edge = pinned.edge
        guard let screen = DockGeometry.target(screens: screens, pinned: pinned.display) else { return }
        let frame = DockGeometry.frame(edge: pinned.edge, on: screen, width: Self.width)
        let animate = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if frame != self.frame { setFrame(frame, display: true, animate: animate) }
    }

    /// Hiding mid-drag ends the drag: the panel goes back to its pinned spot.
    override func orderOut(_ sender: Any?) {
        super.orderOut(sender)
        guard isDragging else { return }
        isDragging = false
        dock(edge: edge)
    }

    /// Brings the panel in. `focus` false (a "now" ask's slide-in)
    /// leaves the frontmost app's focus alone; either way it stays until hidden.
    /// `animated` fades it in over `DS.Motion.fade` (instant under Reduce Motion).
    /// A show during a hide's fade-out cancels it and fades back to full alpha.
    func present(focus: Bool, animated: Bool) {
        fadeToken += 1
        isFadingOut = false
        dock(edge: edge)
        let duration = animated ? DS.appKitDuration(DS.Motion.fade) : 0
        if duration > 0, !isVisible || alphaValue < 1 {
            if !isVisible { alphaValue = 0 }
            orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = duration
                self.animator().alphaValue = 1
            }
        } else {
            alphaValue = 1
            orderFrontRegardless()
        }
        if focus { makeKey() }
    }

    func show() {
        present(focus: true, animated: true)
    }

    /// Hotkey, icon click, Esc at the list, ⌘W and the header ✕ all hide through here.
    func hide(animated: Bool) {
        guard isVisible else { return }
        fadeToken += 1
        let token = fadeToken
        let duration = animated ? DS.appKitDuration(DS.Motion.fade) : 0
        guard duration > 0 else {
            isFadingOut = false
            orderOut(nil)
            alphaValue = 1
            return
        }
        isFadingOut = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            self.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated { self?.finishHide(token) }
        }
    }

    private func finishHide(_ token: Int) {
        guard token == fadeToken else { return }
        isFadingOut = false
        orderOut(nil)
        alphaValue = 1
    }

    /// §4.1: show and focus; focus a visible unfocused panel; re-dock a misplaced one; hide a focused one.
    /// A panel that is fading out counts as hidden, so a second press brings it back. Every
    /// action but hide goes through `present`, which re-docks and cancels a fade-out.
    func toggle() {
        switch PanelToggle.decide(visible: isShown, isKey: isKeyWindow, frame: frame, target: targetFrame ?? frame) {
        case .showAndFocus, .focus, .redockAndFocus:
            present(focus: true, animated: true)
        case .hide:
            hide(animated: true)
        }
    }
}
