import Testing
@testable import RelayCore

private let displays = [MenuDisplay(id: "A", name: "Studio Display"), MenuDisplay(id: "B", name: "Built-in Retina Display")]

private func inputs(notSetUp: Bool = false, visible: Bool = false,
                    shortcut: HotkeySpec? = HotkeySpec.parse("ctrl+opt+cmd+r"),
                    presence: PresenceMode = .auto, pinned: String? = nil) -> MenuInputs {
    MenuInputs(notSetUp: notSetUp, panelVisible: visible, shortcut: shortcut,
               statusLine: "Mailbox · ready · updated 10:42", presenceLine: "Home · active",
               presence: presence, displays: displays, pinned: pinned)
}

/// "—" for a separator, "<title> ▸" for a submenu.
private func titles(_ entries: [MenuEntry]) -> [String] {
    entries.map { entry in
        switch entry {
        case .item(let title, _, _, _, _, _): title
        case .submenu(let title, _): title + " ▸"
        case .separator: "—"
        }
    }
}

private func item(_ entries: [MenuEntry], _ title: String) -> MenuEntry? {
    entries.first { if case .item(let t, _, _, _, _, _) = $0 { t == title } else { false } }
}

private func submenu(_ entries: [MenuEntry], _ title: String) -> [MenuEntry] {
    for entry in entries { if case .submenu(let t, let inner) = entry, t == title { return inner } }
    return []
}

@Suite struct MenuBarMenuTests {
    @Test func theMenuHasTheSpecTitlesInOrder() {
        #expect(titles(MenuBarMenu.entries(inputs())) == [
            "Show Hook", "—", "Mailbox · ready · updated 10:42", "Home · active", "Presence ▸", "—",
            "Refresh", "Panel ▸", "—", "Settings…", "About Hook", "Check for Updates…", "—", "Quit Hook",
        ])
    }

    @Test func anAvailableUpdateComesFirstAndCheckForUpdatesIsAlwaysThere() {
        var withUpdate = inputs()
        withUpdate.updateVersion = "0.6.5"
        let entries = MenuBarMenu.entries(withUpdate)
        #expect(Array(titles(entries).prefix(3)) == ["Update Hook to 0.6.5…", "—", "Show Hook"])
        #expect(item(entries, "Update Hook to 0.6.5…")
            == .item(title: "Update Hook to 0.6.5…", action: .update, key: nil, modifiers: [], enabled: true, checked: false))
        #expect(item(MenuBarMenu.entries(inputs()), "Check for Updates…")
            == .item(title: "Check for Updates…", action: .checkForUpdates, key: nil, modifiers: [], enabled: true, checked: false))
        #expect(!titles(MenuBarMenu.entries(inputs())).contains { $0.hasPrefix("Update Hook") })
    }

    @Test func setUpRelayShowsOnlyWhileNotSetUp() {
        #expect(titles(MenuBarMenu.entries(inputs(notSetUp: true))).first == "Set Up Hook…")
        #expect(item(MenuBarMenu.entries(inputs(notSetUp: true)), "Set Up Hook…")
            == .item(title: "Set Up Hook…", action: .setUp, key: nil, modifiers: [], enabled: true, checked: false))
        #expect(!titles(MenuBarMenu.entries(inputs())).contains("Set Up Hook…"))
    }

    @Test func theToggleSaysHideWhileVisibleAndShowsTheShortcut() {
        #expect(item(MenuBarMenu.entries(inputs()), "Show Hook")
            == .item(title: "Show Hook", action: .togglePanel, key: "r",
                     modifiers: [.control, .option, .command], enabled: true, checked: false))
        #expect(item(MenuBarMenu.entries(inputs(visible: true)), "Hide Hook") != nil)
        #expect(item(MenuBarMenu.entries(inputs(shortcut: nil)), "Show Hook")
            == .item(title: "Show Hook", action: .togglePanel, key: nil, modifiers: [], enabled: true, checked: false))
    }

    @Test func statusAndPresenceLinesAreDisabled() {
        let entries = MenuBarMenu.entries(inputs())
        #expect(item(entries, "Mailbox · ready · updated 10:42")
            == .item(title: "Mailbox · ready · updated 10:42", action: nil, key: nil, modifiers: [], enabled: false, checked: false))
        #expect(item(entries, "Home · active")
            == .item(title: "Home · active", action: nil, key: nil, modifiers: [], enabled: false, checked: false))
    }

    @Test func presenceIsARadioOfThreeModes() {
        let presence = submenu(MenuBarMenu.entries(inputs(presence: .home)), "Presence")
        #expect(presence == [
            .item(title: "Automatic", action: .setPresence(.auto), key: nil, modifiers: [], enabled: true, checked: false),
            .item(title: "Home", action: .setPresence(.home), key: nil, modifiers: [], enabled: true, checked: true),
            .item(title: "Away", action: .setPresence(.away), key: nil, modifiers: [], enabled: true, checked: false),
        ])
    }

    @Test func keyEquivalentsMatchTheKeyboardMap() {
        let entries = MenuBarMenu.entries(inputs())
        #expect(item(entries, "Refresh") == .item(title: "Refresh", action: .refresh, key: "r", modifiers: [.command], enabled: true, checked: false))
        #expect(item(entries, "Settings…") == .item(title: "Settings…", action: .settings, key: ",", modifiers: [.command], enabled: true, checked: false))
        #expect(item(entries, "About Hook") == .item(title: "About Hook", action: .about, key: nil, modifiers: [], enabled: true, checked: false))
        #expect(item(entries, "Quit Hook") == .item(title: "Quit Hook", action: .quit, key: "q", modifiers: [.command], enabled: true, checked: false))
    }

    @Test func thePanelSubmenuDocksAndListsDisplays() {
        let panel = submenu(MenuBarMenu.entries(inputs()), "Panel")
        #expect(titles(panel) == ["Dock Left", "Dock Right", "—", "Main display", "Studio Display",
                                  "Built-in Retina Display", "—", "Re-dock Now"])
        #expect(item(panel, "Dock Left") == .item(title: "Dock Left", action: .dock(.left), key: "\u{F702}",
                                                  modifiers: [.control, .command], enabled: true, checked: false))
        #expect(item(panel, "Dock Right") == .item(title: "Dock Right", action: .dock(.right), key: "\u{F703}",
                                                   modifiers: [.control, .command], enabled: true, checked: false))
        #expect(item(panel, "Re-dock Now") == .item(title: "Re-dock Now", action: .redock, key: nil, modifiers: [], enabled: true, checked: false))
    }

    @Test func theDisplayRadioFollowsThePin() {
        func checked(_ pinned: String?) -> [String] {
            submenu(MenuBarMenu.entries(inputs(pinned: pinned)), "Panel").compactMap {
                if case .item(let title, .pinDisplay, _, _, _, true) = $0 { title } else { nil }
            }
        }
        #expect(checked(nil) == ["Main display"])
        #expect(checked("B") == ["Built-in Retina Display"])
        #expect(checked("GONE") == [])     // the pin is kept while its display is away
        #expect(item(submenu(MenuBarMenu.entries(inputs()), "Panel"), "Studio Display")
            == .item(title: "Studio Display", action: .pinDisplay("A"), key: nil, modifiers: [], enabled: true, checked: false))
    }

    @Test func functionKeyAndSpaceShortcutsMapToMenuKeys() {
        let f5 = MenuBarMenu.keyEquivalent(for: HotkeySpec.parse("f5")!)
        #expect(f5?.key == "\u{F708}" && f5?.modifiers == [])
        let space = MenuBarMenu.keyEquivalent(for: HotkeySpec.parse("shift+cmd+space")!)
        #expect(space?.key == " " && space?.modifiers == [.shift, .command])
        let digit = MenuBarMenu.keyEquivalent(for: HotkeySpec.parse("opt+cmd+1")!)
        #expect(digit?.key == "1" && digit?.modifiers == [.option, .command])
    }
}
