import RelayUIMac
import AppKit
import RelayCore
import RelayUI

/// The status item: the outline hook, or a filled fish on the hook while an ask that
/// arrived with the panel hidden is unseen (`UnseenAsks`). Both are template images, so
/// macOS tints them for the bar; the fish replaces the old red dot. The glyph looks
/// disabled while offline or away. The tooltip is always set. Left click toggles the
/// sidebar; right click or control-click opens the menu, rebuilt from
/// `MenuBarMenu.entries` on every open.
@MainActor final class MenuBarController: NSObject {
    private var item: NSStatusItem
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

    /// One fixed length for both glyphs, so the item never shifts when an ask arrives.
    /// `update(_:)` sets the glyph.
    private static func makeItem() -> NSStatusItem {
        // Without a saved position each relaunch puts the icon at the far left, behind the notch.
        StatusItemPosition.seedIfNeeded(UserDefaults.standard)
        let item = NSStatusBar.system.statusItem(withLength: DS.Metric.menuBarItem)
        item.button?.image = image(for: MenuBarState())
        return item
    }

    /// The state's glyph; the checklist symbol only if the glyph files are missing.
    private static func image(for state: MenuBarState) -> NSImage? {
        if let glyph = MenuBarGlyphImage.image(for: state) { return glyph }
        let symbol = NSImage(systemSymbolName: DS.Symbol.menuBarFallback,
                             accessibilityDescription: state.glyph.accessibilityDescription)
        symbol?.isTemplate = true
        return symbol
    }

    private func configure() {
        guard let button = item.button else { return }
        button.title = ""
        button.imagePosition = .imageOnly
        button.target = self
        button.action = #selector(clicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    /// A menu bar rebuilt after a display change can leave the button without a window.
    /// The new item gets the current state's glyph back from `update(state)`.
    @objc private func screenParametersChanged() {
        guard item.button?.window == nil else { return }
        NSStatusBar.system.removeStatusItem(item)
        item = Self.makeItem()
        configure()
        update(state)
    }

    func update(_ state: MenuBarState) {
        self.state = state
        guard let button = item.button else { return }
        let image = Self.image(for: state)
        if button.image !== image { button.image = image }  // the fish while an ask is unseen
        button.appearsDisabled = state.symbolDimmed        // offline or away
        button.toolTip = state.tooltip                      // always
        button.setAccessibilityLabel(state.accessibilityLabel)
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
