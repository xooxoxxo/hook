import Foundation
import Testing
@testable import RelayCore

/// A throwaway defaults domain; the caller removes it.
private func scratchDefaults() -> (UserDefaults, String) {
    let name = "relay-settings-tests-\(UUID().uuidString)"
    return (UserDefaults(suiteName: name)!, name)
}

private let legacyKey = "relay.settings.tab"
private let home = "/home/tester"

private func screen(_ id: String, primary: Bool) -> DockScreen {
    DockScreen(id: id, frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
               visibleFrame: CGRect(x: 0, y: 70, width: 1440, height: 805), isPrimary: primary)
}

@Suite struct SettingsLogicTests {
    @Test func theSavedTabIDWins() {
        let (defaults, name) = scratchDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("panel", forKey: SettingsTabID.defaultsKey)
        defaults.set(3, forKey: legacyKey)
        #expect(SettingsTabID.restore(defaults) == .panel)
        #expect(defaults.object(forKey: legacyKey) == nil)
    }

    @Test func aLegacyIndexMapsToTheOldFourTabs() {
        let expected: [(Int, SettingsTabID)] = [(0, .general), (1, .queue), (2, .notifications), (3, .connect)]
        for (index, tab) in expected {
            let (defaults, name) = scratchDefaults()
            defer { defaults.removePersistentDomain(forName: name) }
            defaults.set(index, forKey: legacyKey)
            #expect(SettingsTabID.restore(defaults) == tab)
            #expect(defaults.string(forKey: SettingsTabID.defaultsKey) == tab.rawValue)
            #expect(defaults.object(forKey: legacyKey) == nil)
        }
    }

    @Test func aLegacyStringIsItsRawValue() {
        for raw in ["connect", "queue", "notifications", "general"] {
            let (defaults, name) = scratchDefaults()
            defer { defaults.removePersistentDomain(forName: name) }
            defaults.set(raw, forKey: legacyKey)
            #expect(SettingsTabID.restore(defaults).rawValue == raw)
            #expect(defaults.string(forKey: SettingsTabID.defaultsKey) == raw)
        }
    }

    @Test func anUnknownLegacyValueFallsBackToGeneralAndIsDeleted() {
        for value: Any in [7, -1, "bogus", "2"] {
            let (defaults, name) = scratchDefaults()
            defer { defaults.removePersistentDomain(forName: name) }
            defaults.set(value, forKey: legacyKey)
            #expect(SettingsTabID.restore(defaults) == .general)
            #expect(defaults.object(forKey: legacyKey) == nil)
        }
    }

    @Test func nothingSavedIsGeneralAndWritesNothing() {
        let (defaults, name) = scratchDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(SettingsTabID.restore(defaults) == .general)
        #expect(defaults.object(forKey: SettingsTabID.defaultsKey) == nil)
    }

    @Test func savingWritesTheID() {
        let (defaults, name) = scratchDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        SettingsTabID.queue.save(defaults)
        #expect(defaults.string(forKey: SettingsTabID.defaultsKey) == "queue")
        #expect(SettingsTabID.restore(defaults) == .queue)
    }

    @Test func commandDigitsPickTheFiveTabsInOrder() {
        #expect((1...5).compactMap(SettingsTabID.init(shortcutDigit:)) == [.general, .panel, .queue, .notifications, .connect])
        #expect(SettingsTabID(shortcutDigit: 0) == nil)
        #expect(SettingsTabID(shortcutDigit: 6) == nil)
    }

    @Test func titlesAndSymbols() {
        #expect(SettingsTabID.allCases.map(\.title) == ["General", "Panel", "Queue", "Notifications", "Connect"])
        #expect(SettingsTabID.allCases.map(\.symbol) == ["gearshape", "sidebar.right", "tray", "bell", "link"])
    }

    @Test func anEmptyDraftAndSnapshotStartBlank() {
        #expect(MailboxDraft() == MailboxDraft(address: "", tokenFile: "", context: ""))
        let snapshot = SettingsSnapshot()
        #expect(snapshot.config == nil && snapshot.sourceKey == SourceKey.none && snapshot.displays.isEmpty)
    }

    @Test func aSkillErrorChangesTheRepoState() {
        #expect(RepoState().skillError == nil)
        let failed = RepoState(repoPath: "~/src/relay", skillError: "Couldn't install the skill. Disk full.")
        #expect(failed != RepoState(repoPath: "~/src/relay"))
        #expect(failed.skillError == "Couldn't install the skill. Disk full.")
    }

    @Test func shortcutProblemsHaveTheSpecTexts() {
        #expect(ShortcutProblem.unsupportedKey.text == "That key can't be used. Pick a letter, a digit, Space, ` or F1–F12.")
        #expect(ShortcutProblem.refused.text == "macOS refused this shortcut. Another app may be using it.")
        #expect(ShortcutProblem.resumeFailed.text == "The shortcut was turned off because macOS refused it again. Record it again.")
    }

    @Test func aRecordingMapsToAProblem() {
        let spec = HotkeySpec.parse("ctrl+opt+cmd+r")
        #expect(ShortcutProblem.forRecording(nil, registered: false) == .unsupportedKey)
        #expect(ShortcutProblem.forRecording(spec, registered: false) == .refused)
        #expect(ShortcutProblem.forRecording(spec, registered: true) == nil)
    }

    @Test func displayChoicesStartWithMainThenEachDisplay() {
        let names = ["P": "Built-in Retina Display", "S": "Studio Display"]
        #expect(DisplayChoice.options(screens: [screen("P", primary: true), screen("S", primary: false)],
                                      names: names, pinned: nil) == [
            DisplayOption(id: nil, title: "Main display", connected: true),
            DisplayOption(id: "P", title: "Built-in Retina Display", connected: true),
            DisplayOption(id: "S", title: "Studio Display", connected: true),
        ])
    }

    @Test func aPinnedDisplayThatIsGoneIsListedDisabled() {
        let names = ["P": "Built-in Retina Display", "S": "Studio Display"]
        let gone = DisplayChoice.options(screens: [screen("P", primary: true)], names: names, pinned: "S")
        #expect(gone.last == DisplayOption(id: "S", title: "Studio Display (not connected)", connected: false))
        #expect(gone.count == 3)
        let unnamed = DisplayChoice.options(screens: [screen("P", primary: true)], names: [:], pinned: "X")
        #expect(unnamed.last == DisplayOption(id: "X", title: "Pinned display (not connected)", connected: false))
        let here = DisplayChoice.options(screens: [screen("P", primary: true)], names: names, pinned: "P")
        #expect(here.count == 2)
    }

    @Test func aDisplayWithoutANameIsCalledDisplay() {
        #expect(DisplayChoice.options(screens: [screen("P", primary: true)], names: [:], pinned: nil)[1].title == "Display")
    }

    @Test func notifySettingsBecomeTheConfigObject() {
        let object = NotifySettings(now: false, today: true, whenever: true, sound: true, slideIn: false).configObject
        #expect(object.count == 5)
        #expect(object["now"] as? Bool == false)
        #expect(object["today"] as? Bool == true)
        #expect(object["whenever"] as? Bool == true)
        #expect(object["sound"] as? Bool == true)
        #expect(object["slideIn"] as? Bool == false)
    }

    @Test func pollAndKeepLabels() {
        #expect(ChoiceLabel.pollChoices == [5, 15, 30, 60, 300])
        #expect(ChoiceLabel.pollChoices.map(ChoiceLabel.poll) == ["5 seconds", "15 seconds", "30 seconds", "1 minute", "5 minutes"])
        #expect(ChoiceLabel.poll(20) == "20 seconds (from config.json)")
        #expect(ChoiceLabel.poll(120) == "120 seconds (from config.json)")
        #expect(ChoiceLabel.keepChoices == [3, 7, 14, 30, 90])
        #expect(ChoiceLabel.keepDays(14) == "14 days")
        #expect(ChoiceLabel.keepDays(45) == "45 days (from config.json)")
    }

    @Test func tildePathsRoundTrip() {
        #expect(TildePath.abbreviate("/home/tester/.config/relay/token", home: home) == "~/.config/relay/token")
        #expect(TildePath.expand("~/.config/relay/token", home: home) == "/home/tester/.config/relay/token")
        #expect(TildePath.expand(TildePath.abbreviate("/home/tester/a b/c", home: home), home: home) == "/home/tester/a b/c")
        #expect(TildePath.expand("~", home: home) == home)
        #expect(TildePath.abbreviate(home, home: home) == "~")
        #expect(TildePath.abbreviate("/home/testerX/a", home: home) == "/home/testerX/a")
        #expect(TildePath.expand("/opt/token", home: home) == "/opt/token")
        #expect(TildePath.expand("~other/token", home: home) == "~other/token")
    }

    @Test func aDraftStartsFromTheConfig() {
        let config = RelayConfig(source: .mailbox, mailboxURL: "https://mailbox.example:8790",
                                 tokenFile: "/home/tester/.config/relay/mailbox-token", context: "work")
        #expect(MailboxDraft(config: config, home: home)
            == MailboxDraft(address: "https://mailbox.example:8790", tokenFile: "~/.config/relay/mailbox-token", context: "work"))
        #expect(MailboxDraft(config: RelayConfig(mailboxURL: "https://m.example", tokenFile: "/t"), home: home).context == "")
        #expect(MailboxDraft(config: nil, home: home) == MailboxDraft())
    }

    @Test func aDraftIsDirtyOnlyWhenAFieldDiffers() {
        let config = RelayConfig(source: .mailbox, mailboxURL: "https://mailbox.example:8790",
                                 tokenFile: "/home/tester/.config/relay/mailbox-token")
        var draft = MailboxDraft(config: config, home: home)
        #expect(!draft.isDirty(against: config, home: home))
        draft.address += "  "
        #expect(!draft.isDirty(against: config, home: home))
        draft.tokenFile = "/home/tester/.config/relay/mailbox-token"
        #expect(!draft.isDirty(against: config, home: home))
        draft.context = "personal"
        #expect(!draft.isDirty(against: config, home: home))
        draft.context = "work"
        #expect(draft.isDirty(against: config, home: home))
        #expect(MailboxDraft(address: "https://m.example").isDirty(against: nil, home: home))
        #expect(!MailboxDraft().isDirty(against: nil, home: home))
    }

    @Test func errorsNameTheBadField() {
        let valid = MailboxDraft(address: "https://mailbox.example:8790", tokenFile: "~/token")
        #expect(valid.errors().address == nil && valid.errors().tokenFile == nil)
        #expect(MailboxDraft(tokenFile: "~/t").errors().address == "Enter the mailbox address.")
        for bad in ["mailbox.example", "ftp://mailbox.example", "http://", "https:// x"] {
            #expect(MailboxDraft(address: bad, tokenFile: "~/t").errors().address
                == "The address must start with http:// or https://.")
        }
        #expect(MailboxDraft(address: "https://m.example", tokenFile: "  ").errors().tokenFile == "Enter the token file.")
    }

    @Test func changesSaveTheMailboxAndExpandTheTilde() {
        let work = MailboxDraft(address: " https://mailbox.example:8790 ", tokenFile: "~/.config/relay/token", context: " work ")
        let saved = work.changes(home: home)
        #expect(NSDictionary(dictionary: saved.set) == NSDictionary(dictionary: [
            "source": "mailbox", "mailboxURL": "https://mailbox.example:8790",
            "tokenFile": "/home/tester/.config/relay/token", "context": "work",
        ]))
        #expect(saved.remove.isEmpty)
        let personal = MailboxDraft(address: "https://m.example", tokenFile: "/t", context: "").changes(home: home)
        #expect(personal.set["context"] == nil)
        #expect(personal.remove == ["context"])
    }

    @Test func connectionNotesShowAsOneRevealedLine() {
        let problems = ConnectionStatus.problems(
            configNote: "config.json isn't valid JSON:\nUnexpected character \u{202E} at line 3",
            listenerNote: "Port 47823 is in use by another app")
        #expect(problems == [
            "config.json isn't valid JSON:⟨U+000A⟩Unexpected character ⟨U+202E⟩ at line 3",
            "Port 47823 is in use by another app",
        ])
        #expect(ConnectionStatus.problems(configNote: nil, listenerNote: nil).isEmpty)
    }

    @Test func thePermissionRowSaysWhatToDo() {
        #expect(NotificationPermission.authorized.statusText == "Allowed")
        #expect(NotificationPermission.authorized.action == nil)
        #expect(NotificationPermission.denied.statusText == "Turned off in System Settings")
        #expect(NotificationPermission.denied.action == .openNotificationSettings)
        #expect(NotificationPermission.denied.actionTitle == "Open System Settings")
        #expect(NotificationPermission.notDetermined.statusText == nil)
        #expect(NotificationPermission.notDetermined.action == .requestNotifications)
        #expect(NotificationPermission.notDetermined.actionTitle == "Allow Notifications…")
        #expect(NotificationPermission.sentFor == 5)
    }
}
