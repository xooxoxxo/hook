import AppKit
import RelayCore
import RelayUI

/// The status item: the template "checklist" symbol with a red dot on its
/// top-right corner while an ask that arrived with the panel hidden is unseen
/// (`UnseenAsks`). The symbol looks disabled while offline or away; the badge
/// dims only while offline. The tooltip is always set. Left click toggles the
/// sidebar; right click or control-click opens the menu, rebuilt from
/// `MenuBarMenu.entries` on every open.
@MainActor final class MenuBarController: NSObject {
    private var item: NSStatusItem
    /// A template image can't carry colour, so the badge is its own view.
    private let badge = BadgeView(frame: .zero)
    private var state = MenuBarState()
    private let inputs: @MainActor () -> MenuInputs
    private let onToggle: @MainActor () -> Void
    private let onAction: @MainActor (MenuAction) -> Void

    init(inputs: @escaping @MainActor () -> MenuInputs,
         onToggle: @escaping @MainActor () -> Void,
         onAction: @escaping @MainActor (MenuAction) -> Void) {
        self.inputs = inputs
        self.onToggle = onToggle
        self.onAction = onAction
        item = Self.makeItem()
        super.init()
        configure()
        NotificationCenter.default.addObserver(
            self, selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        update(MenuBarState())
    }

    /// The template "checklist" symbol, `symbolWidth + 8` wide so the badge never clips.
    private static func makeItem() -> NSStatusItem {
        let image = NSImage(systemSymbolName: DS.Symbol.menuBar, accessibilityDescription: "Hook")
        image?.isTemplate = true
        // Without a saved position each relaunch puts the icon at the far left, behind the notch.
        StatusItemPosition.seedIfNeeded(.standard)
        let item = NSStatusBar.system.statusItem(withLength: (image?.size.width ?? 16) + 8)
        item.button?.image = image
        return item
    }

    private func configure() {
        guard let button = item.button else { return }
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
    }

    /// A menu bar rebuilt after a display change can leave the button without a window.
    @objc private func screenParametersChanged() {
        guard item.button?.window == nil else { return }
        if let old = item.button {
            NotificationCenter.default.removeObserver(self, name: NSView.frameDidChangeNotification, object: old)
        }
        NSStatusBar.system.removeStatusItem(item)
        item = Self.makeItem()
        configure()
        update(state)
    }

    func update(_ state: MenuBarState) {
        self.state = state
        guard let button = item.button else { return }
        button.appearsDisabled = state.symbolDimmed        // offline or away
        button.toolTip = state.tooltip                      // always
        button.setAccessibilityLabel(state.accessibilityLabel)
        badge.badge = state.badge
        badge.dimmed = state.dimmed                         // 0.5 only offline; away keeps full alpha
        button.layoutSubtreeIfNeeded()
        placeBadge(in: button)
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
        Self.menu(MenuBarMenu.entries(inputs()), target: self)
    }

    private static func menu(_ entries: [MenuEntry], target: MenuBarController) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for entry in entries {
            switch entry {
            case .separator:
                menu.addItem(.separator())
            case let .submenu(title, inner):
                let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                holder.submenu = Self.menu(inner, target: target)
                menu.addItem(holder)
            case let .item(title, action, key, modifiers, enabled, checked):
                let item = NSMenuItem(title: title, action: action == nil ? nil : #selector(chosen(_:)),
                                      keyEquivalent: key ?? "")
                item.keyEquivalentModifierMask = Self.flags(modifiers)
                item.target = action == nil ? nil : target
                item.representedObject = action.map(ActionBox.init)
                item.isEnabled = enabled
                item.state = checked ? .on : .off
                menu.addItem(item)
            }
        }
        return menu
    }

    private static func flags(_ modifiers: KeyModifiers) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if modifiers.contains(.command) { flags.insert(.command) }
        if modifiers.contains(.shift) { flags.insert(.shift) }
        if modifiers.contains(.option) { flags.insert(.option) }
        if modifiers.contains(.control) { flags.insert(.control) }
        return flags
    }

    @objc private func chosen(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? ActionBox else { return }
        onAction(box.action)
    }
}

/// A `MenuAction` carried in `NSMenuItem.representedObject`.
private final class ActionBox: NSObject {
    let action: MenuAction
    init(_ action: MenuAction) { self.action = action }
}
