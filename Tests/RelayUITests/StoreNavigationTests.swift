import Foundation
import RelayCore
import Testing
@testable import RelayUI

private let threeAcme = [item("a", created: stamp(minutesAgo: 10)), item("b", created: stamp(minutesAgo: 20)),
                         item("n", project: "Northwind", urgency: "now", created: stamp(minutesAgo: 30))]

@Suite @MainActor struct StoreNavigationTests {
    @Test func groupingIsRestoredByANewStore() {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let first = Store(defaults: defaults.defaults)
        #expect(first.grouping == .project)
        first.setGrouping(.urgency)
        #expect(Store(defaults: defaults.defaults).grouping == .urgency)
    }

    @Test func theFilterIsPerSourceAndRestored() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let first = Store(defaults: defaults.defaults)
        await start(first, FakeQueueSource(items: threeAcme))
        first.setFilter("Acme")
        #expect(first.filter == "Acme")

        let second = Store(defaults: defaults.defaults)
        await start(second, FakeQueueSource(items: threeAcme))
        #expect(second.filter == "Acme")
        await start(second, FakeQueueSource(items: threeAcme), identity: mailboxIdentity)
        #expect(second.filter == nil)
    }

    @Test func theSelectionIsRestoredPerSource() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let first = Store(defaults: defaults.defaults)
        await start(first, FakeQueueSource(items: threeAcme))
        first.listSelection = "b"

        let second = Store(defaults: defaults.defaults)
        await start(second, FakeQueueSource(items: threeAcme))
        second.settleSelection()
        #expect(second.listSelection == "b")
        await start(second, FakeQueueSource(items: threeAcme), identity: mailboxIdentity)
        second.settleSelection()
        #expect(second.listSelection == "n")
    }

    @Test func layoutFollowsGroupingAndFilter() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let store = Store(defaults: defaults.defaults)
        await start(store, FakeQueueSource(items: threeAcme))
        #expect(store.sections.map(\.header) == [.project("Northwind"), .project("Acme")])
        #expect(store.visibleOrder == ["n", "a", "b"])
        #expect(store.menuProjects == [MenuProject(name: "Acme", open: 2), MenuProject(name: "Northwind", open: 1)])
        store.setGrouping(.urgency)
        #expect(store.visibleOrder == ["n", "a", "b"])
        #expect(store.sections.map(\.header) == [.urgency(.now), .urgency(.today)])
        store.setFilter("Acme")
        #expect(store.visibleOrder == ["a", "b"])
        #expect(store.hiddenCount == HiddenCount(total: 1, now: 1))
    }

    @Test func groupingKeepsTheSelectionAndTheFilterKeepsItWhenShown() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let store = Store(defaults: defaults.defaults)
        await start(store, FakeQueueSource(items: threeAcme))
        store.listSelection = "b"
        store.setGrouping(.urgency)
        #expect(store.listSelection == "b")
        store.setFilter("Acme")
        #expect(store.listSelection == "b")
        store.setFilter("Northwind")
        #expect(store.listSelection == "n")
        #expect(PanelPrefs.selection(defaults.defaults, sourceKey: "local") == "n")
    }

    @Test func aFilterOutlivesItsAsks() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let store = Store(defaults: defaults.defaults)
        let fake = FakeQueueSource(items: threeAcme)
        await start(store, fake)
        store.setFilter("Northwind")
        await fake.setItems(Array(threeAcme.prefix(2)))
        await store.refresh()
        #expect(store.visibleOrder.isEmpty)
        #expect(store.filter == "Northwind")
        #expect(PanelPrefs.filter(defaults.defaults, sourceKey: "local") == "Northwind")
    }

    @Test func openAndBack() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let store = Store(defaults: defaults.defaults)
        let fake = FakeQueueSource(items: threeAcme)
        // The first poll's detail fetch for "n" fails, so opening it must fetch it again.
        await fake.failNext(QueueError.unreachable("down"), on: "get n")
        await start(store, fake)
        #expect(store.details["n"] == nil)
        store.setFilter("Acme")
        store.listSelection = "a"
        store.open("b")
        #expect(store.navigation == PanelNavigation(listSelection: "b", selectedID: "b"))
        #expect(store.navigation.selectedID == "b")
        store.back()
        #expect(store.navigation == PanelNavigation(listSelection: "b", selectedID: nil))
        store.open("n")
        #expect(store.navigation == PanelNavigation(listSelection: "b", selectedID: "n"))
        #expect(await eventually { await fake.count("get n") >= 2 && store.details["n"] != nil })
    }

    @Test func aClosedAskCanBeOpened() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let store = Store(defaults: defaults.defaults)
        let fake = FakeQueueSource(items: threeAcme)
        await fake.setClosed([closed(item("c", created: stamp(minutesAgo: 90)))])
        await start(store, fake)
        #expect(store.closedShown.map(\.id) == ["c"])
        #expect(store.item(for: "c")?.status == "done")
        store.open("c")
        #expect(store.navigation.listSelection == "c")
    }

    @Test func refreshOnShowOnlyWhenStaleAndOnlyForAMailbox() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let clock = TestClock()
        let store = Store(defaults: defaults.defaults, now: { clock.now })
        let fake = FakeQueueSource(items: threeAcme)
        await start(store, fake, identity: mailboxIdentity)
        #expect(store.lastListAt == clock.now)
        let before = await fake.count("list")
        clock.advance(4)
        await store.refreshIfStale()
        #expect(await fake.count("list") == before)
        clock.advance(2)
        await store.refreshIfStale()
        #expect(await fake.count("list") == before + 1)

        let local = Store(defaults: defaults.defaults, now: { clock.now })
        let localFake = FakeQueueSource(items: threeAcme)
        await start(local, localFake)
        clock.advance(60)
        let localBefore = await localFake.count("list")
        await local.refreshIfStale()
        #expect(await localFake.count("list") == localBefore)
    }

    @Test func theSpinnerIsOnlyForManualRefreshes() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let store = Store(defaults: defaults.defaults)
        let fake = FakeQueueSource(items: threeAcme)
        await start(store, fake)
        await fake.setListDelay(.milliseconds(300))

        let background = Task { await store.refresh() }
        #expect(await eventually { store.refreshing })
        #expect(!store.manualRefreshing)
        await background.value

        let manual = Task { await store.refresh(manual: true) }
        #expect(await eventually { store.manualRefreshing })
        await manual.value
        #expect(!store.manualRefreshing)
    }

    /// N9: the spinner ends on failure too; a list that never answers is bounded by the transport's timeout.
    @Test func theSpinnerEndsWhenTheListFails() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let store = Store(defaults: defaults.defaults)
        let fake = FakeQueueSource(items: threeAcme)
        await start(store, fake)
        let before = await fake.count("list")
        await fake.failNext(QueueError.unreachable("down"), on: "list")
        await store.refresh(manual: true)
        #expect(await fake.count("list") == before + 1)
        #expect(!store.reachable)
        #expect(!store.manualRefreshing)
    }
}
