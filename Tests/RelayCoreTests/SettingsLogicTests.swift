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
}
