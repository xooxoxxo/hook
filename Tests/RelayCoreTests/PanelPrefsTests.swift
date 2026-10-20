import Foundation
import Testing
@testable import RelayCore

@Suite struct PanelPrefsTests {
    @Test func keys() {
        #expect(PanelPrefs.groupingKey == "relay.queue.grouping")
        #expect(PanelPrefs.filterKey(sourceKey: "local") == "relay.queue.filter.local")
        #expect(PanelPrefs.selectionKey(sourceKey: "mailbox:m#p") == "relay.panel.selection.mailbox:m#p")
    }

    @Test func groupingDefaultsToProject() throws {
        try withDefaults { d in
            #expect(PanelPrefs.grouping(d) == .project)
            d.set("columns", forKey: PanelPrefs.groupingKey)
            #expect(PanelPrefs.grouping(d) == .project)
            d.set(3, forKey: PanelPrefs.groupingKey)
            #expect(PanelPrefs.grouping(d) == .project)
            PanelPrefs.setGrouping(.urgency, d)
            #expect(d.string(forKey: PanelPrefs.groupingKey) == "urgency")
            #expect(PanelPrefs.grouping(d) == .urgency)
        }
    }

    @Test func filterIsPerSourceAndRaw() throws {
        try withDefaults { d in
            #expect(PanelPrefs.filter(d, sourceKey: "local") == nil)
            PanelPrefs.setFilter("Ac\nme", d, sourceKey: "local")
            #expect(PanelPrefs.filter(d, sourceKey: "local") == "Ac\nme")
            #expect(PanelPrefs.filter(d, sourceKey: "mailbox:m#p") == nil)
            PanelPrefs.setFilter("", d, sourceKey: "mailbox:m#p")
            #expect(PanelPrefs.filter(d, sourceKey: "mailbox:m#p") == "")
            PanelPrefs.setFilter(nil, d, sourceKey: "local")
            #expect(d.object(forKey: "relay.queue.filter.local") == nil)
        }
    }

    @Test func everythingSurvivesARelaunch() throws {
        let suite = "relay.tests.prefs.\(UUID().uuidString)"
        let first = try #require(UserDefaults(suiteName: suite))
        defer { first.removePersistentDomain(forName: suite) }
        PanelPrefs.setGrouping(.urgency, first)
        PanelPrefs.setFilter("Atlas", first, sourceKey: "local")
        PanelPrefs.setSelection("a1", first, sourceKey: "local")

        let relaunched = try #require(UserDefaults(suiteName: suite))
        #expect(PanelPrefs.grouping(relaunched) == .urgency)
        #expect(PanelPrefs.filter(relaunched, sourceKey: "local") == "Atlas")
        #expect(PanelPrefs.selection(relaunched, sourceKey: "local") == "a1")
    }

    @Test func selectionNilRemoves() throws {
        try withDefaults { d in
            PanelPrefs.setSelection("a1", d, sourceKey: "local")
            PanelPrefs.setSelection(nil, d, sourceKey: "local")
            #expect(PanelPrefs.selection(d, sourceKey: "local") == nil)
            #expect(d.object(forKey: "relay.panel.selection.local") == nil)
        }
    }
}
