import Foundation
import Testing
@testable import RelayCore

/// A throwaway defaults domain; the caller removes it.
private func scratchDefaults() -> (UserDefaults, String) {
    let name = "relay-settings-tests-\(UUID().uuidString)"
    return (UserDefaults(suiteName: name)!, name)
}

private let legacyKey = "relay.settings.tab"

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
}
