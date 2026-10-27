import AppKit
import QuartzCore
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
    /// The panel-wide keys; AppDelegate sets it once the panel hosts PanelRoot.
    var keyRouter: PanelKeyRouter?
    /// Every show and slide-in: the menu bar's unseen asks are seen now.
    var onShown: (@MainActor () -> Void)?
    /// Reads `sidebarDisplay` and saves a pin from a header drag; set by `connect(_:)`.
    private weak var model: AppModel?
    private var docker: PanelDocker?
    /// True from the first move of a header drag until `pin(at:)` or a hide.
    /// Re-docks wait meanwhile, so the panel stays under the pointer.
    private(set) var isDragging = false
    /// The frame when the current header drag began; the drag moves it by the pointer's travel.
    private var dragStart: CGRect?

    /// Bumped by every show and hide, so a fade-out that finishes after a new show
    /// doesn't order the panel out.
    private var fadeToken = 0
    /// True from a slide-in until the panel hides; that hide reverses the slide.
    /// Focusing the panel ends it, so a focused panel fades when it hides.
    private(set) var slidIn = false

    /// True while a hide's fade-out (or a slide-in's reverse) runs. The panel is still
    /// ordered in then, but it is on its way out, so the toggle rule and a "now" ask
    /// treat it as hidden.
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
        // Hook moves the panel itself: the header drag and PanelDock.
        isMovable = false
        // Never shown (no title bar), but it names the window for VoiceOver and the Window menu.
        title = "Hook"
        setAccessibilityLabel("Hook")

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
        docker = PanelDocker(window: self) { [weak self] in
            guard let self else { return }
            self.dock(edge: self.edge, animated: true)
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

    /// Full height of the pinned display's visible frame, `DS.Metric.panelWidth` wide, on `edge`.
    /// A pinned display that isn't connected falls back to the main display; the pin
    /// is kept, so the panel goes back when it reconnects. Runs while hidden too, so
    /// the next show is already in place. A visible panel snaps when `animated`.
    func dock(edge: SidebarEdge, animated: Bool = false) {
        self.edge = edge
        guard !isDragging, let frame = targetFrame, frame != self.frame else { return }
        if animated, isVisible {
            snap(to: frame)
        } else {
            setFrame(frame, display: true)
        }
    }

    /// `DS.Motion.snap`: 0.20 s ease-out, instant under Reduce Motion.
    private func snap(to frame: CGRect) {
        let duration = DS.appKitDuration(DS.Motion.snap)
        guard duration > 0 else {
            setFrame(frame, display: true)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self.animator().setFrame(frame, display: true)
        }
    }

    /// ⌃⌘← / ⌃⌘→, the menu's Dock Left / Dock Right and the header's VoiceOver actions:
    /// pins `edge` on the display the panel is on now. The save is the pin.
    func dock(_ edge: SidebarEdge) {
        var set: [String: Any] = ["sidebarEdge": edge.rawValue]
        if let display = DockGeometry.currentScreenID(frame: frame, screens: NSScreen.dockScreens) {
            set["sidebarDisplay"] = display
        }
        model?.save(set: set)
        dock(edge: model?.config?.sidebarEdge ?? edge, animated: true)
    }

    /// Double-click on the header, the menu's Re-dock Now and Settings → Panel → Re-dock Now.
    func redock() {
        dock(edge: model?.config?.sidebarEdge ?? edge, animated: true)
    }

    /// A header drag passed the 3 pt threshold; re-docks wait until it ends.
    func beginDrag() {
        isDragging = true
        dragStart = frame
        NSCursor.closedHand.set()
    }

    /// The pointer moved `delta` (screen points, y up) since the press.
    func drag(by delta: CGSize) {
        guard isDragging, let dragStart else { return }
        setFrame(DockGeometry.dragFrame(start: dragStart, delta: delta), display: true)
    }

    /// The end of a header drag at `point` (screen coordinates): pins the panel
    /// to that display's nearer edge, saves `sidebarEdge` and `sidebarDisplay`,
    /// and slides it into place (no slide with Reduce Motion). The slide goes
    /// where the reloaded config says, so a save that fails, or a reload that
    /// keeps the last good config, slides the panel back to its old spot.
    func pin(at point: NSPoint) {
        guard isDragging else { return }
        let screens = NSScreen.dockScreens
        let snap = DockGeometry.snap(point: point, screens: screens)
        if let snap, let model {
            model.save(set: ["sidebarEdge": snap.edge.rawValue, "sidebarDisplay": snap.screenID])
        }
        isDragging = false
        dragStart = nil
        let pinned: (edge: SidebarEdge, display: String?)
        if let model {
            pinned = (model.config?.sidebarEdge ?? edge, model.config?.sidebarDisplay)
        } else {
            pinned = (snap?.edge ?? edge, snap?.screenID)
        }
        edge = pinned.edge
        guard let screen = DockGeometry.target(screens: screens, pinned: pinned.display) else { return }
        let frame = DockGeometry.frame(edge: pinned.edge, on: screen, width: Self.width)
        if frame != self.frame { self.snap(to: frame) }
    }

    /// Hiding mid-drag ends the drag: the panel goes back to its pinned spot.
    override func orderOut(_ sender: Any?) {
        super.orderOut(sender)
        guard isDragging else { return }
        isDragging = false
        dragStart = nil
        dock(edge: edge)
    }

    /// Brings the panel in. `focus` false leaves the frontmost app's focus alone;
    /// either way it stays until hidden. `focus` true ends a slide-in.
    /// `animated` fades it in over `DS.Motion.fade` (instant under Reduce Motion).
    /// A show during a hide's fade-out cancels it and fades back to full alpha.
    func present(focus: Bool, animated: Bool) {
        fadeToken += 1
        isFadingOut = false
        if focus { slidIn = false }
        // A visible panel off its docked frame (the toggle's re-dock case) snaps back.
        dock(edge: edge, animated: true)
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
        onShown?()
    }

    /// A "now" ask while the panel is hidden: from beyond the edge to the docked frame,
    /// 0.25 s ease-out, never key, so Terminal keeps typing. Under Reduce Motion it fades
    /// in at the docked frame over 0.12 s. A panel that is fading out counts as hidden.
    func slideIn() {
        guard !isShown else { return }
        fadeToken += 1
        isFadingOut = false
        dock(edge: edge)
        let docked = targetFrame ?? frame
        slidIn = true
        onShown?()
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            setFrame(docked, display: false)
            if !isVisible { alphaValue = 0 }
            orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = DS.appKitDuration(DS.Motion.slideIn)
                self.animator().alphaValue = 1
            }
            return
        }
        alphaValue = 1
        setFrame(SlideIn.offscreenFrame(docked: docked, edge: edge), display: false)
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = DS.appKitDuration(DS.Motion.slideIn)
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self.animator().setFrame(docked, display: true)
        }
    }

    func show() {
        present(focus: true, animated: true)
    }

    /// Hotkey, icon click, Esc at the list, ⌘W and the header ✕ all hide through here.
    func hide(animated: Bool) {
        guard isVisible else { return }
        if slidIn, animated {
            slideOut()
            return
        }
        slidIn = false
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

    /// The hide after a slide-in reverses it: back beyond the edge, 0.25 s ease-out.
    /// Under Reduce Motion the slide-in was a 0.12 s fade, so its reverse is too.
    private func slideOut() {
        slidIn = false
        fadeToken += 1
        let token = fadeToken
        isFadingOut = true
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = DS.appKitDuration(DS.Motion.slideIn)
                self.animator().alphaValue = 0
            } completionHandler: { [weak self] in
                MainActor.assumeIsolated { self?.finishHide(token) }
            }
            return
        }
        let docked = targetFrame ?? frame
        NSAnimationContext.runAnimationGroup { context in
            context.duration = DS.appKitDuration(DS.Motion.slideIn)
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self.animator().setFrame(SlideIn.offscreenFrame(docked: docked, edge: self.edge), display: true)
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated { self?.finishSlideOut(token, docked: docked) }
        }
    }

    /// Orders the slid-out panel out and puts it back on its docked frame for the next show.
    private func finishSlideOut(_ token: Int, docked: CGRect) {
        guard token == fadeToken else { return }
        isFadingOut = false
        orderOut(nil)
        setFrame(docked, display: false)
    }

    private func finishHide(_ token: Int) {
        guard token == fadeToken else { return }
        isFadingOut = false
        orderOut(nil)
        alphaValue = 1
    }

    /// Called by the shortcut, a left click on the status item and the menu's Show/Hide Panel item: show and focus;
    /// re-dock a misplaced one; hide a docked one. The shortcut and the menu item focus a visible unfocused panel
    /// instead of hiding it; a status-item click hides it. A panel that is fading out counts as hidden, so a second press brings it back. Every
    /// action but hide goes through `present`, which re-docks and cancels a fade-out.
    func toggle(from source: ToggleSource) {
        switch PanelToggle.decide(source: source, visible: isShown, isKey: isKeyWindow, frame: frame, target: targetFrame ?? frame) {
        case .showAndFocus, .focus, .redockAndFocus:
            present(focus: true, animated: true)
        case .hide:
            hide(animated: true)
        }
    }
}

/// Lets the SwiftUI header reach the panel before the panel exists.
@MainActor final class PanelRef {
    weak var panel: SidePanel?
}

extension PanelDragActions {
    /// Header press → drag → snap and pin; a double-click re-docks to the saved spot.
    @MainActor static func panel(_ ref: PanelRef) -> PanelDragActions {
        PanelDragActions(
            began: { ref.panel?.beginDrag() },
            moved: { ref.panel?.drag(by: $0) },
            ended: { ref.panel?.pin(at: $0) },
            doubleClicked: { ref.panel?.redock() })
    }
}
