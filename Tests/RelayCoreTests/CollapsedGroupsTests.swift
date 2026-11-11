import Foundation
import Testing
@testable import RelayCore

@Suite struct CollapsedGroupsTests {
    @Test func keysNameTheGroupingAndTheGroup() {
        #expect(CollapsedGroups.key(.project("Acme")) == "project:Acme")
        #expect(CollapsedGroups.key(.project("")) == "project:")
        #expect(CollapsedGroups.key(.urgency(.now)) == "urgency:now")
        #expect(CollapsedGroups.key(.urgency(.today)) == "urgency:today")
        // A project called "Now" and the Now urgency group keep separate states.
        var groups = CollapsedGroups()
        groups.set(.project("Now"), collapsed: true)
        #expect(groups.isCollapsed(.project("Now")))
        #expect(!groups.isCollapsed(.urgency(.now)))
    }

    @Test func toggleAndRoundTripThroughJSON() {
        var groups = CollapsedGroups()
        groups.toggle(.project("Acme"))
        groups.toggle(.urgency(.today))
        #expect(groups.json == #"["project:Acme","urgency:today"]"#)
        let read = CollapsedGroups(json: groups.json)
        #expect(read == groups)
        groups.toggle(.project("Acme"))
        #expect(groups.keys == ["urgency:today"])
    }

    @Test func unreadableStoreIsEverythingOpen() {
        #expect(CollapsedGroups(json: "").keys.isEmpty)
        #expect(CollapsedGroups(json: "{not json").keys.isEmpty)
        #expect(CollapsedGroups(json: #"{"a":1}"#).keys.isEmpty)
        #expect(CollapsedGroups(json: "[]").json == "[]")
    }

    @Test func collapseAllTouchesOnlyTheListedGroups() {
        var groups = CollapsedGroups(keys: ["urgency:now"])
        let shown: [QueueSection.Header] = [.project("Acme"), .project("")]
        #expect(groups.canCollapseAll(shown))
        #expect(!groups.canExpandAll(shown))
        groups.setAll(shown, collapsed: true)
        #expect(groups.keys == ["project:Acme", "project:", "urgency:now"])
        #expect(!groups.canCollapseAll(shown))
        #expect(groups.canExpandAll(shown))
        groups.setAll(shown, collapsed: false)
        // The other grouping's state is kept.
        #expect(groups.keys == ["urgency:now"])
    }

    @Test func collapseAllNeverReachesRecentlyClosed() {
        // Recently closed is not a QueueSection, so it is never among the headers, and its
        // flag lives under its own UserDefaults key.
        let defaults = UserDefaults(suiteName: "CollapsedGroupsTests-\(UUID().uuidString)")!
        defaults.set(false, forKey: "relay.closedToday.expanded")
        let sections = [QueueSection(header: .project("Acme"), items: []), QueueSection(header: .project("Beta"), items: [])]
        CollapsedGroups.update(defaults) { $0.setAll(CollapsedGroups.headers(sections), collapsed: true) }
        #expect(defaults.string(forKey: CollapsedGroups.defaultsKey) == #"["project:Acme","project:Beta"]"#)
        #expect(defaults.object(forKey: "relay.closedToday.expanded") as? Bool == false)
        CollapsedGroups.update(defaults) { $0.setAll(CollapsedGroups.headers(sections), collapsed: false) }
        #expect(defaults.string(forKey: CollapsedGroups.defaultsKey) == "[]")
        #expect(defaults.object(forKey: "relay.closedToday.expanded") as? Bool == false)
        #expect(CollapsedGroups.defaultsKey != "relay.closedToday.expanded")
    }

    @Test func flatListHasNoGroups() {
        let flat = [QueueSection(header: nil, items: [])]
        #expect(CollapsedGroups.headers(flat).isEmpty)
        #expect(!CollapsedGroups().canCollapseAll([]))
        #expect(!CollapsedGroups().canExpandAll([]))
    }

    @Test func newestIsTheLatestCreated() {
        func row(_ id: String, _ created: String) -> AskRowModel {
            AskRowModel(id: id, title: "T \(id)", project: "Acme", urgency: .today, created: created, summary: .none)
        }
        let rows = [row("a", "2026-10-16T08:00:00+00:00"), row("b", "2026-10-16T09:00:00+00:00"),
                    row("c", "not a date"), row("d", "2026-10-16T09:00:00+00:00")]
        #expect(CollapsedGroups.newest(rows)?.id == "b")
        #expect(CollapsedGroups.newest([row("c", "")])?.id == "c")
        #expect(CollapsedGroups.newest([]) == nil)
    }
}
