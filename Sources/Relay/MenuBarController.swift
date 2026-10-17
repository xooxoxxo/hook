import AppKit
import RelayCore
import RelayUI

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
        badge.dimmed = state.dimmed
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
        let bounds = button.bounds
        let image = button.cell?.imageRect(forBounds: bounds) ?? bounds
        badge.frame = BadgeGeometry.frame(for: badge.badge, in: bounds, imageRect: image, flipped: button.isFlipped)
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
