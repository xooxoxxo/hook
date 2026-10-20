import Foundation
import Testing
@testable import RelayCore

/// A throwaway defaults domain; the caller removes it.
private func scratchDefaults() -> (UserDefaults, String) {
    let name = "relay-settings-tests-\(UUID().uuidString)"
    return (UserDefaults(suiteName: name)!, name)
}

private let legacyKey = "relay.settings.tab"

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
}
