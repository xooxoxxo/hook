import AppKit
import RelayCore

/// The status item: the template "checklist" symbol with a red
/// badge on its top-right corner while any ask is open (the count when it fits
/// in one digit, else a plain dot), dimming when the source is unreachable, a
/// fainter symbol while away, and the right-click menu. Left click toggles the sidebar.
@MainActor final class MenuBarController: NSObject {
    private let item: NSStatusItem
    /// A template image can't carry colour, so the badge is its own view.
    private let badge: BadgeView
    private var shortcutLabel = "Shortcut: (not set)"
    private var presenceLine = "Home · active"
    private var presenceMode: PresenceMode = .auto
    private let onPresence: @MainActor (PresenceMode) -> Void
    private let onToggle: @MainActor () -> Void
    private let onRefresh: @MainActor () -> Void
    private let onSettings: @MainActor () -> Void
    private let onQuit: @MainActor () -> Void

    init(
        onToggle: @escaping @MainActor () -> Void,
        onRefresh: @escaping @MainActor () -> Void,
        onSettings: @escaping @MainActor () -> Void,
        onPresence: @escaping @MainActor (PresenceMode) -> Void,
        onQuit: @escaping @MainActor () -> Void
    ) {
        self.onPresence = onPresence
        self.onToggle = onToggle
        self.onRefresh = onRefresh
        self.onSettings = onSettings
        self.onQuit = onQuit
        badge = BadgeView(frame: .zero)
        let image = NSImage(systemSymbolName: "checklist", accessibilityDescription: "Relay")
        image?.isTemplate = true
        // Fixed width with room on the right, so the badge overlaps only the
        // symbol's corner and is never clipped by the button's bounds.
        item = NSStatusBar.system.statusItem(withLength: (image?.size.width ?? 16) + 8)
        super.init()
        guard let button = item.button else { return }
        button.image = image
        button.title = ""
        button.imagePosition = .imageOnly
        button.target = self
        button.action = #selector(clicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.addSubview(badge)
        // A taller or shorter menu bar (another screen) resizes the button without a
        // state change, so the badge is placed again whenever the frame changes.
        button.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(buttonFrameChanged(_:)),
            name: NSView.frameDidChangeNotification, object: button)
        update(MenuBarState())
    }

    func update(_ state: MenuBarState) {
        guard let button = item.button else { return }
        button.appearsDisabled = state.symbolDimmed
        button.toolTip = state.tooltip
        button.setAccessibilityLabel(state.accessibilityLabel)
        badge.badge = state.badge
        badge.isHidden = state.badge == .none
        badge.alphaValue = state.dimmed ? 0.5 : 1
        button.layoutSubtreeIfNeeded()
        placeBadge(in: button)
    }

    func setShortcutLabel(_ text: String) {
        shortcutLabel = text
    }

    /// The menu's presence line ("Away · screen locked · since 10:22") and the
    /// ticked item in Presence.
    func setPresence(line: String, mode: PresenceMode) {
        presenceLine = line
        presenceMode = mode
    }

    /// Over the symbol's top-right corner, clamped inside the button's bounds.
    /// Positioned from the bounds and the image rect, so taller menu bars
    /// (notched MacBooks) need no special case.
    private func placeBadge(in button: NSStatusBarButton) {
        let size = badge.diameter
        let bounds = button.bounds
        let image = button.cell?.imageRect(forBounds: bounds) ?? bounds
        let x = min(max(image.maxX - size * 0.6, bounds.minX), bounds.maxX - size)
        let y = button.isFlipped ? image.minY - size * 0.35 : image.maxY - size * 0.65
        badge.frame = NSRect(
            x: x, y: min(max(y, bounds.minY), bounds.maxY - size),
            width: size, height: size)
        badge.needsDisplay = true
    }

    @objc private func buttonFrameChanged(_ note: Notification) {
        guard let button = item.button else { return }
        placeBadge(in: button)
    }

    /// Left click toggles the sidebar; right click or control-click opens the menu.
    @objc private func clicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            item.menu = makeMenu()
            item.button?.performClick(nil)
            item.menu = nil
        } else {
            onToggle()
        }
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let status = NSMenuItem(title: presenceLine, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        let presence = NSMenuItem(title: "Presence", action: nil, keyEquivalent: "")
        presence.isEnabled = true
        let choices = NSMenu()
        choices.autoenablesItems = false
        for (mode, title) in [(PresenceMode.auto, "Automatic"), (.home, "Home"), (.away, "Away")] {
            let choice = entry(title, #selector(presenceClicked(_:)))
            choice.representedObject = mode.rawValue
            choice.state = mode == presenceMode ? .on : .off
            choices.addItem(choice)
        }
        presence.submenu = choices
        menu.addItem(presence)
        menu.addItem(.separator())
        menu.addItem(entry("Refresh", #selector(refreshClicked)))
        menu.addItem(entry("Settings…", #selector(settingsClicked)))
        let shortcut = NSMenuItem(title: shortcutLabel, action: nil, keyEquivalent: "")
        shortcut.isEnabled = false
        menu.addItem(shortcut)
        menu.addItem(.separator())
        menu.addItem(entry("Quit Relay", #selector(quitClicked)))
        return menu
    }

    private func entry(_ title: String, _ action: Selector) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
        entry.target = self
        entry.isEnabled = true
        return entry
    }

    @objc private func refreshClicked() { onRefresh() }
    @objc private func settingsClicked() { onSettings() }
    @objc private func quitClicked() { onQuit() }
    @objc private func presenceClicked(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let mode = PresenceMode(rawValue: raw) else { return }
        onPresence(mode)
    }
}

/// The red badge: a 12 pt circle with a white digit, or a plain 7 pt dot.
/// Redraws on appearance changes and never takes clicks.
private final class BadgeView: NSView {
    var badge: MenuBarBadge = .none {
        didSet { if badge != oldValue { needsDisplay = true } }
    }

    var diameter: CGFloat {
        if case .number = badge { return 12 }
        return 7
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard badge != .none else { return }
        NSColor.systemRed.setFill()
        NSBezierPath(ovalIn: bounds).fill()
        guard case .number(let count) = badge,
              let context = NSGraphicsContext.current?.cgContext else { return }
        let text = NSAttributedString(string: "\(count)", attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .bold),
            .foregroundColor: NSColor.white,
        ])
        // Centre the digit's ink, not its line box, so it looks optically centred.
        let line = CTLineCreateWithAttributedString(text)
        let ink = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        context.saveGState()
        context.textMatrix = .identity
        context.textPosition = CGPoint(x: bounds.midX - ink.midX, y: bounds.midY - ink.midY)
        CTLineDraw(line, context)
        context.restoreGState()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
