import Foundation
@testable import RelayCore
import SwiftUI
import Testing
@testable import RelayUI

private let three = [item("a", urgency: "now", created: stamp(minutesAgo: 10), steps: 3, substeps: [1: 3]),
                     item("b", created: stamp(minutesAgo: 20)),
                     item("n", project: "Northwind", created: stamp(minutesAgo: 30))]

@Suite @MainActor struct SnapshotTests {
    @Test func storeQueueSnapshot() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let store = Store(defaults: defaults.defaults)
        await start(store, FakeQueueSource(items: three))
        store.toggleTick("2.1", in: "a")
        var queue = store.queue
        #expect(queue.title == "3 waiting")
        #expect(queue.content == .list)
        #expect(queue.sourceName == "This Mac")
        #expect(queue.sections.map(\.header) == [.project("Acme"), .project("Northwind")])
        #expect(queue.rows["a"]?.summary == .steps(done: 1, total: 5))
        #expect(queue.rows["a"]?.urgency == .now)
        #expect(queue.hidden == .zero)

        store.setFilter("Acme")
        queue = store.queue
        #expect(queue.title == "2 waiting")
        #expect(queue.hidden == HiddenCount(total: 1, now: 0))
        #expect(queue.sections.map(\.header) == [nil])
        #expect(queue.projects.map(\.name) == ["Acme", "Northwind"])

        store.setFilter("Atlas")
        #expect(store.queue.title == "Queue")
        #expect(store.queue.content == .emptyFiltered(project: "Atlas"))
    }

    @Test func storeDetailSnapshot() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let store = Store(defaults: defaults.defaults)
        await start(store, FakeQueueSource(items: three))
        store.open("a")
        #expect(await eventually { store.detail("a")?.load == .loaded })
        store.toggleTick("1", in: "a")
        store.drafts["a"] = "C07"
        let detail = store.detail("a")
        #expect(detail?.current == "2.1")
        #expect(detail?.progress == StepProgress(done: 1, total: 5))
        #expect(detail?.primary == .sendAndDone)
        #expect(detail?.previous == .end)
        #expect(detail?.next == .ask("b"))
        #expect(detail?.closedText == nil)
        #expect(detail?.row.hasDraft == true)
        #expect(store.detail("missing") == nil)
    }

    @Test func storeStatusAndKeyContext() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let store = Store(defaults: defaults.defaults)
        await start(store, FakeQueueSource(items: three))
        #expect(store.status == PanelStatus(symbol: .ok, text: "This Mac · ready", detail: .updated))
        store.away = true
        #expect(store.status.text == "Away · This Mac · ready")
        store.listSelection = "a"
        let list = store.keyContext(textFieldFocused: false, popoverOpen: false, closedHeaderFocused: false)
        #expect(list.mode == .list && list.selectionOpen == true && list.selectionHasProject)
        store.open("a")
        store.drafts["a"] = "x"
        let detail = store.keyContext(textFieldFocused: true, popoverOpen: false, closedHeaderFocused: false)
        #expect(detail.mode == .detail && detail.textFieldFocused && detail.hasDraftOrPick && detail.askOpen)
    }

    @Test func performRoutesCommands() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let store = Store(defaults: defaults.defaults)
        var copied: [String] = []
        store.shell = PanelShellActions(hide: {}, setUp: {}, quit: {}, dock: { _ in }, openSettings: { _ in },
                                        copy: { copied.append($0) }, openURL: { _ in })
        await start(store, FakeQueueSource(items: three))
        store.perform(.switchGrouping)
        #expect(store.grouping == .urgency)
        store.listSelection = "n"
        store.perform(.showOnlyProject)
        #expect(store.filter == "Northwind")
        store.perform(.clearFilter)
        #expect(store.filter == nil)
        store.perform(.copyLink)
        #expect(copied == ["relay://i/n"])
        store.perform(.openSelection)
        #expect(store.selectedID == "n")
        store.perform(.pickChoice(1))
        #expect(store.pendingChoice["n"] == 1)
        store.perform(.back)
        #expect(store.selectedID == nil)
    }

    @Test func fixturesBuild() {
        #expect(GalleryFixtures.now == Timestamp.date("2026-10-16T09:40:00+00:00"))
        #expect(GalleryFixtures.open.count == 5)
        #expect(Set(GalleryFixtures.open.compactMap(\.projectId)) == ["Acme", "Relay", "Northwind"])
        let steps = GalleryFixtures.detailSteps
        #expect(steps.progress == StepProgress(done: 2, total: 8))
        #expect(steps.model?.nodes.map(\.path) == ["1", "2", "3", "4", "5", "verify"])
        #expect(steps.model?.nodes[1].children.map(\.label) == ["2a", "2b", "2c"])
        #expect(steps.model?.origin?.session == "1b2c3d4e-0000-4000-8000-000000000001")
        #expect(GalleryFixtures.detailChoice.model?.reply?.choices?.count == 2)

        let limits = GalleryFixtures.limits
        #expect(limits.row.title.count == 120)
        #expect(limits.model?.nodes.count == 21)
        #expect(limits.progress.total == 57)
        #expect(limits.model?.reply?.choices?.allSatisfy { $0.count == 60 } == true)
        #expect(limits.model?.links.count == 10)
        #expect(limits.model?.nodes.contains { $0.content.detail?.count == 1500 } == true)
        #expect(limits.model?.nodes.contains { $0.content.code?.count == 4000 } == true)

        let queue = GalleryFixtures.queue(grouping: .project, filter: nil, closedExpanded: true)
        #expect(queue.title == "5 waiting")
        #expect(queue.sections.count == 3)
        #expect(queue.rows["acme-1"]?.summary == .steps(done: 2, total: 8))
        #expect(queue.closed.count == 2)
        #expect(GalleryFixtures.queue(grouping: .project, filter: "Acme", closedExpanded: false).hidden == HiddenCount(total: 2, now: 0))
        #expect(Set(GalleryFixtures.manyProjects.compactMap(\.projectId)).count == 12)
        #expect(GalleryFixtures.manyProjects.contains { $0.projectId?.count == 60 })
    }

    @Test func fixturesPassTheValidator() throws {
        for item in GalleryFixtures.open + [GalleryFixtures.limitsItem] {
            let data = try JSONEncoder().encode(item.instructable)
            let value = try JSONValue.parse(data)
            guard case .success = Validator.validate(value) else {
                Issue.record("\(item.id) isn't a valid instructable")
                continue
            }
        }
    }

    @Test func aFixtureModelServesItsSnapshots() {
        let model = FixturePanelModel(queue: GalleryFixtures.queue(grouping: .urgency, filter: nil, closedExpanded: true),
                                      details: ["acme-1": GalleryFixtures.detailSteps],
                                      status: PanelStatus(symbol: .ok, text: "Mailbox · ready", detail: .updated))
        #expect(model.detail("acme-1") == GalleryFixtures.detailSteps)
        #expect(model.detail("nope") == nil)
        model.setGrouping(.project)
        #expect(model.queue.grouping == .urgency)
        model.listSelection = "acme-2"
        #expect(model.navigation.listSelection == "acme-2")
    }

    /// Controller ruling (Task 14 review): the 10 s "Still trying…" flip happens with no other state change.
    @Test func theStillTryingFlipNeedsNoOtherChange() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let clock = TestClock()
        let store = Store(defaults: defaults.defaults, now: { clock.now },
                          timeoutSleep: { duration in await clock.advance(Double(duration.components.seconds)) })
        let source = FakeQueueSource(items: three)
        await source.setListDelay(.seconds(3600))
        store.swap(to: source, identity: localIdentity, pollSeconds: 3600)
        #expect(store.queue.content == .loading(stillTrying: false))
        #expect(await eventually { store.stateTick == 1 })
        #expect(store.queue.content == .loading(stillTrying: true))
        store.swap(to: nil, identity: localIdentity, pollSeconds: 3600)
    }
}

@MainActor @Suite struct PanelRootTests {
    @Test func detailShowsOnlyWithAnOpenAsk() {
        #expect(!PanelRoot<FixturePanelModel>.showsDetail(PanelNavigation()))
        #expect(!PanelRoot<FixturePanelModel>.showsDetail(PanelNavigation(listSelection: "a1")))
        #expect(PanelRoot<FixturePanelModel>.showsDetail(PanelNavigation(listSelection: "a1", selectedID: "a1")))
        // An ask outside the filter (slide-in, link) opens with no list selection.
        #expect(PanelRoot<FixturePanelModel>.showsDetail(PanelNavigation(selectedID: "outside")))
    }

    @Test func galleryOverridesDefaultToNothing() {
        let overrides = EnvironmentValues().panelGallery
        #expect(overrides == PanelGalleryOverrides())
        #expect(overrides.now == nil && overrides.closedExpanded == nil && overrides.fromExpanded == nil && overrides.fullHeight == nil)
    }
}
