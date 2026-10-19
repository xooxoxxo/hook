import Foundation
import Testing
@testable import RelayCore

/// An ask created `hoursAgo` hours before 2026-10-16T09:40:00Z.
func ask(_ id: String, _ project: String?, _ urgency: String?, hoursAgo: Double,
         steps: [Step] = [Step(action: "Do it")], verify: Step? = nil, reply: ReplySpec? = nil) -> WireItem {
    let base = Timestamp.date("2026-10-16T09:40:00+00:00")!
    let created = Timestamp.string(base.addingTimeInterval(-hoursAgo * 3600))
    let ins = Instructable(v: 1, title: "Ask \(id)", urgency: urgency, steps: steps, verify: verify, reply: reply)
    return WireItem(id: id, title: "Ask \(id)", status: "open", projectId: project, created: created, updated: created,
                    payload: Payload(why: nil, cmd: nil, link: nil, instructable: ins))
}

private func ids(_ sections: [QueueSection]) -> [[String]] { sections.map { $0.items.map(\.id) } }

@Suite struct QueueLayoutTests {
    @Test func projectsWithANowAskComeFirst() {
        let items = [ask("a1", "Acme", "today", hoursAgo: 1), ask("n1", "Northwind", "now", hoursAgo: 30),
                     ask("r1", "Relay", "whenever", hoursAgo: 2)]
        let sections = QueueLayout.sections(items: items, grouping: .project, filter: nil)
        #expect(sections.map(\.header) == [.project("Northwind"), .project("Acme"), .project("Relay")])
        #expect(sections.map(\.id) == ["project.Northwind", "project.Acme", "project.Relay"])
    }

    @Test func thenTheNewestAskWins() {
        let items = [ask("a1", "Acme", "today", hoursAgo: 5), ask("r1", "Relay", "today", hoursAgo: 1),
                     ask("a2", "Acme", "whenever", hoursAgo: 0.5)]
        #expect(QueueLayout.sections(items: items, grouping: .project, filter: nil).map(\.header)
            == [.project("Acme"), .project("Relay")])
    }

    @Test func aTieGoesToTheName() {
        let items = [ask("z", "acme 10", "today", hoursAgo: 1), ask("y", "Acme 2", "today", hoursAgo: 1),
                     ask("x", "Atlas", "today", hoursAgo: 1)]
        #expect(QueueLayout.sections(items: items, grouping: .project, filter: nil).map(\.header)
            == [.project("Acme 2"), .project("acme 10"), .project("Atlas")])
    }

    @Test func rowsByUrgencyThenNewestFirst() {
        let items = [ask("w", "Acme", "whenever", hoursAgo: 0.1), ask("t-old", "Acme", "today", hoursAgo: 9),
                     ask("u", "Acme", "soon", hoursAgo: 4), ask("n", "Acme", "now", hoursAgo: 20),
                     ask("t-new", "Acme", nil, hoursAgo: 2), ask("r", "Relay", "today", hoursAgo: 1)]
        let sections = QueueLayout.sections(items: items, grouping: .project, filter: nil)
        #expect(ids(sections) == [["n", "t-new", "u", "t-old", "w"], ["r"]])
    }

    @Test func oneProjectOrAFilterIsFlat() {
        let one = [ask("a1", "Acme", "today", hoursAgo: 3), ask("a2", "Acme", "now", hoursAgo: 5)]
        let flat = QueueLayout.sections(items: one, grouping: .project, filter: nil)
        #expect(flat.count == 1 && flat[0].header == nil && flat[0].id == "flat")
        #expect(ids(flat) == [["a2", "a1"]])

        let many = one + [ask("r1", "Relay", "now", hoursAgo: 1)]
        let filtered = QueueLayout.sections(items: many, grouping: .project, filter: "Acme")
        #expect(filtered.map(\.header) == [nil])
        #expect(ids(filtered) == [["a2", "a1"]])
        #expect(QueueLayout.sections(items: many, grouping: .project, filter: "Atlas").isEmpty)
        #expect(QueueLayout.sections(items: [], grouping: .project, filter: nil).isEmpty)
    }

    @Test func noProjectIsItsOwnSection() {
        let items = [ask("a1", "Acme", "today", hoursAgo: 1), ask("x", nil, "today", hoursAgo: 2), ask("y", "", "today", hoursAgo: 3)]
        let sections = QueueLayout.sections(items: items, grouping: .project, filter: nil)
        #expect(sections.map(\.header) == [.project("Acme"), .project("")])
        #expect(ids(sections) == [["a1"], ["x", "y"]])
        #expect(ids(QueueLayout.sections(items: items, grouping: .project, filter: "")) == [["x", "y"]])
    }

    @Test func urgencyGroupingKeepsSourceOrder() {
        let items = [ask("t1", "Acme", "today", hoursAgo: 1), ask("w1", "Relay", "whenever", hoursAgo: 2),
                     ask("u1", "Atlas", "soon", hoursAgo: 3), ask("n1", "Acme", "now", hoursAgo: 4),
                     ask("t2", "Relay", nil, hoursAgo: 5)]
        let sections = QueueLayout.sections(items: items, grouping: .urgency, filter: nil)
        #expect(sections.map(\.header) == [.urgency(.now), .urgency(.today), .urgency(.whenever)])
        #expect(sections.map(\.id) == ["urgency.now", "urgency.today", "urgency.whenever"])
        #expect(ids(sections) == [["n1"], ["t1", "u1", "t2"], ["w1"]])
        #expect(ids(QueueLayout.sections(items: items, grouping: .urgency, filter: "Relay")) == [["t2"], ["w1"]])
    }

    @Test func visibleOrderAndMatches() {
        let items = [ask("a1", "Acme", "today", hoursAgo: 1), ask("n1", "Northwind", "now", hoursAgo: 2)]
        #expect(QueueLayout.visibleOrder(QueueLayout.sections(items: items, grouping: .project, filter: nil)) == ["n1", "a1"])
        #expect(QueueLayout.matches(items[0], filter: nil))
        #expect(QueueLayout.matches(items[0], filter: "Acme"))
        #expect(!QueueLayout.matches(items[0], filter: "acme"))
    }
}

@Suite struct QueueFilterTests {
    private let items = [ask("a1", "Acme", "today", hoursAgo: 1), ask("a2", "Acme", "now", hoursAgo: 2),
                         ask("n1", "Northwind", "now", hoursAgo: 3), ask("r1", "Relay", "whenever", hoursAgo: 4)]

    @Test func hiddenCount() {
        #expect(QueueLayout.hiddenCount(items: items, filter: nil) == .zero)
        #expect(QueueLayout.hiddenCount(items: items, filter: "Acme") == HiddenCount(total: 2, now: 1))
        #expect(QueueLayout.hiddenCount(items: items, filter: "Northwind") == HiddenCount(total: 3, now: 1))
        #expect(QueueLayout.hiddenCount(items: items, filter: "Relay") == HiddenCount(total: 3, now: 2))
    }

    @Test func menuProjects() {
        #expect(QueueLayout.menuProjects(items: items, filter: nil)
            == [MenuProject(name: "Acme", open: 2), MenuProject(name: "Northwind", open: 1), MenuProject(name: "Relay", open: 1)])
        #expect(QueueLayout.menuProjects(items: items, filter: "Atlas")
            == [MenuProject(name: "Acme", open: 2), MenuProject(name: "Atlas", open: 0),
                MenuProject(name: "Northwind", open: 1), MenuProject(name: "Relay", open: 1)])
        #expect(QueueLayout.menuProjects(items: [ask("x", nil, "today", hoursAgo: 1)], filter: nil) == [MenuProject(name: "", open: 1)])
    }

    @Test func closedFollowsTheFilter() {
        let closed = [ask("c1", "Acme", "today", hoursAgo: 1), ask("c2", "Relay", "today", hoursAgo: 2)]
        #expect(QueueLayout.closed(closed, filter: nil).map(\.id) == ["c1", "c2"])
        #expect(QueueLayout.closed(closed, filter: "Relay").map(\.id) == ["c2"])
        #expect(QueueLayout.closed(closed, filter: "Atlas").isEmpty)
    }

    @Test func filterWorksInBothGroupings() {
        #expect(QueueLayout.visibleOrder(QueueLayout.sections(items: items, grouping: .project, filter: "Acme")) == ["a2", "a1"])
        #expect(QueueLayout.visibleOrder(QueueLayout.sections(items: items, grouping: .urgency, filter: "Acme")) == ["a2", "a1"])
    }
}

@Suite struct RowSummaryTests {
    private let eight = [Step(action: "1"), Step(action: "2", substeps: (1...4).map { Step(action: "s\($0)") }),
                         Step(action: "3"), Step(action: "4")]

    @Test func leafCountMatchesTheTree() {
        let item = ask("a", "Acme", "today", hoursAgo: 1, steps: eight, verify: Step(action: "Check"))
        let ins = item.instructable!
        #expect(QueueLayout.leafCount(ins) == 8)
        #expect(QueueLayout.leafCount(ins) == Flow.leaves(of: DetailModel.nodes(steps: ins.steps, verify: ins.verify)).count)
        let empty = Instructable(v: 1, title: "t", steps: [Step(action: "a", substeps: [])])
        #expect(QueueLayout.leafCount(empty) == 1)
        let many = Instructable(v: 1, title: "t", steps: [Step(action: "a", substeps: (1...12).map { Step(action: "\($0)") })])
        #expect(QueueLayout.leafCount(many) == 10)
    }

    @Test func stepsCountTickedLeaves() {
        let item = ask("a", "Acme", "today", hoursAgo: 1, steps: eight, verify: Step(action: "Check"))
        #expect(QueueLayout.summary(for: item, ticked: []) == .steps(done: 0, total: 8))
        #expect(QueueLayout.summary(for: item, ticked: ["1", "2.1"]) == .steps(done: 2, total: 8))
        #expect(QueueLayout.summary(for: item, ticked: ["1", "2.1"]).text == "2 of 8")
    }

    @Test func steplessAndLegacyAsks() {
        let choose = ask("c", "Acme", "today", hoursAgo: 1, steps: [], reply: ReplySpec(prompt: "Pick", choices: ["a", "b", "c"]))
        #expect(QueueLayout.summary(for: choose, ticked: []) == .choose(3))
        let reply = ask("r", "Acme", "today", hoursAgo: 1, steps: [], reply: ReplySpec(prompt: "Say", choices: nil))
        #expect(QueueLayout.summary(for: reply, ticked: []) == .reply)
        #expect(QueueLayout.summary(for: ask("n", "Acme", "today", hoursAgo: 1, steps: []), ticked: []) == .none)
        func legacy(cmd: String?, link: String?) -> WireItem {
            WireItem(id: "l", title: "L", status: "open", projectId: "Acme", created: "2026-10-16T09:00:00+00:00",
                     updated: "2026-10-16T09:00:00+00:00", payload: Payload(why: nil, cmd: cmd, link: link, instructable: nil))
        }
        #expect(QueueLayout.summary(for: legacy(cmd: "ls", link: nil), ticked: []) == .legacyCmd)
        #expect(QueueLayout.summary(for: legacy(cmd: " ", link: "https://example.com"), ticked: []) == .legacyLink)
        #expect(QueueLayout.summary(for: legacy(cmd: nil, link: nil), ticked: []) == .none)
    }
}
