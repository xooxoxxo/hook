import Foundation

/// What a menu-bar menu item does; MenuBarController maps it to AppDelegate.
public enum MenuAction: Equatable, Sendable {
    case setUp, togglePanel, setPresence(PresenceMode), refresh, dock(SidebarEdge), pinDisplay(String?), redock
    case settings, about, update, checkForUpdates, updateMailbox, quit
}

public indirect enum MenuEntry: Equatable, Sendable {
    /// `key` is an NSMenuItem key equivalent (lowercase, or an NSEvent function-key
    /// character); nil shows none. `action` nil is an information line.
    case item(title: String, action: MenuAction?, key: String?, modifiers: KeyModifiers, enabled: Bool, checked: Bool)
    case submenu(title: String, entries: [MenuEntry])
    case separator
}

public struct MenuDisplay: Equatable, Sendable {
    public var id: String
    public var name: String
    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

public struct MenuInputs: Equatable, Sendable {
    public var notSetUp: Bool
    public var panelVisible: Bool
    public var shortcut: HotkeySpec?
    public var statusLine: String
    public var presenceLine: String
    public var presence: PresenceMode
    public var displays: [MenuDisplay]
    public var pinned: String?
    /// A newer release ("0.6.5"), or nil.
    public var updateVersion: String?
    /// Asks come from a mailbox, so Update Mailbox… is offered.
    public var mailbox: Bool

    public init(notSetUp: Bool, panelVisible: Bool, shortcut: HotkeySpec?, statusLine: String,
                presenceLine: String, presence: PresenceMode, displays: [MenuDisplay], pinned: String?,
                updateVersion: String? = nil, mailbox: Bool = false) {
        self.notSetUp = notSetUp
        self.panelVisible = panelVisible
        self.shortcut = shortcut
        self.statusLine = statusLine
        self.presenceLine = presenceLine
        self.presence = presence
        self.displays = displays
        self.pinned = pinned
        self.updateVersion = updateVersion
        self.mailbox = mailbox
    }
}

/// The menu-bar menu, rebuilt on every open.
public enum MenuBarMenu {
    /// NSLeftArrowFunctionKey and NSRightArrowFunctionKey.
    static let leftArrow = "\u{F702}"
    static let rightArrow = "\u{F703}"
    /// NSF1FunctionKey; F2…F12 follow it.
    static let f1: UInt32 = 0xF704

    public static func entries(_ inputs: MenuInputs) -> [MenuEntry] {
        var entries: [MenuEntry] = []
        if let version = inputs.updateVersion {
            entries.append(action("Update Hook to \(Sanitize.revealLine(version))…", .update))
            entries.append(.separator)
        }
        // The only way into setup before Hook is set up; afterwards it is in About Hook.
        if inputs.notSetUp { entries.append(action("Set Up Hook…", .setUp)) }
        let toggle = inputs.panelVisible ? "Hide Hook" : "Show Hook"
        if let spec = inputs.shortcut, let key = keyEquivalent(for: spec) {
            entries.append(action(toggle, .togglePanel, key: key.key, modifiers: key.modifiers))
        } else {
            entries.append(action(toggle, .togglePanel))
        }
        entries.append(.separator)
        entries.append(info(inputs.statusLine))
        entries.append(info(inputs.presenceLine))
        entries.append(.submenu(title: "Presence", entries: [
            action("Automatic", .setPresence(.auto), checked: inputs.presence == .auto),
            action("Home", .setPresence(.home), checked: inputs.presence == .home),
            action("Away", .setPresence(.away), checked: inputs.presence == .away),
        ]))
        entries.append(.separator)
        entries.append(action("Refresh", .refresh, key: "r", modifiers: [.command]))
        var panel: [MenuEntry] = [
            action("Dock Left", .dock(.left), key: leftArrow, modifiers: [.control, .command]),
            action("Dock Right", .dock(.right), key: rightArrow, modifiers: [.control, .command]),
            .separator,
            action("Main display", .pinDisplay(nil), checked: inputs.pinned == nil),
        ]
        for display in inputs.displays {
            panel.append(action(display.name, .pinDisplay(display.id), checked: display.id == inputs.pinned))
        }
        panel += [.separator, action("Re-dock Now", .redock)]
        entries.append(.submenu(title: "Panel", entries: panel))
        entries.append(.separator)
        entries.append(action("Settings…", .settings, key: ",", modifiers: [.command]))
        entries.append(action("About Hook", .about))
        entries.append(action("Check for Updates…", .checkForUpdates))
        if inputs.mailbox { entries.append(action("Update Pond…", .updateMailbox)) }
        entries.append(.separator)
        entries.append(action("Quit Hook", .quit, key: "q", modifiers: [.command]))
        return entries
    }

    /// The global shortcut as a menu key equivalent (display only: Carbon handles the press).
    public static func keyEquivalent(for spec: HotkeySpec) -> (key: String, modifiers: KeyModifiers)? {
        guard let name = HotkeySpec.keyNames[spec.keyCode] else { return nil }
        var modifiers: KeyModifiers = []
        if spec.carbonModifiers & HotkeySpec.controlBit != 0 { modifiers.insert(.control) }
        if spec.carbonModifiers & HotkeySpec.optionBit != 0 { modifiers.insert(.option) }
        if spec.carbonModifiers & HotkeySpec.shiftBit != 0 { modifiers.insert(.shift) }
        if spec.carbonModifiers & HotkeySpec.cmdBit != 0 { modifiers.insert(.command) }
        if name == "space" { return (" ", modifiers) }
        if name.count >= 2, name.hasPrefix("f"), let n = UInt32(name.dropFirst()), (1...12).contains(n),
           let scalar = Unicode.Scalar(f1 + n - 1) {
            return (String(Character(scalar)), modifiers)
        }
        return (name, modifiers)
    }

    private static func action(_ title: String, _ action: MenuAction, key: String? = nil,
                               modifiers: KeyModifiers = [], checked: Bool = false) -> MenuEntry {
        .item(title: title, action: action, key: key, modifiers: modifiers, enabled: true, checked: checked)
    }

    private static func info(_ title: String) -> MenuEntry {
        .item(title: title, action: nil, key: nil, modifiers: [], enabled: false, checked: false)
    }
}
