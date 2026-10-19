import Foundation
import RelayCore
import Testing
@testable import RelayUI

private let abc = [item("a", created: stamp(minutesAgo: 10)), item("b", created: stamp(minutesAgo: 20)),
                   item("c", created: stamp(minutesAgo: 30))]

@MainActor private func ready(_ items: [WireItem] = abc, clock: TestClock = TestClock(), defaults: TestDefaults)
    async -> (Store, FakeQueueSource) {
    let store = Store(defaults: defaults.defaults, now: { clock.now })
    let fake = FakeQueueSource(items: items)
    await start(store, fake)
    return (store, fake)
}

@Suite @MainActor struct StoreCloseTests {
    @Test func principleOneThreeClosesOpenTheNextEachTime() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let (store, _) = await ready(defaults: defaults)
        store.open("a")
        store.close("a", .done)
        #expect(store.selectedID == "b")
        store.close("b", .done)
        #expect(store.selectedID == "c")
        store.close("c", .declined)
        #expect(store.navigation == PanelNavigation(listSelection: nil, selectedID: nil))
        #expect(store.items.isEmpty)
        #expect(store.undoInfo?.more == 2)
    }

    @Test func afterCloseQueueGoesBackWithTheNextSelected() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let (store, _) = await ready(defaults: defaults)
        store.afterClose = .queue
        store.open("b")
        store.close("b", .done)
        #expect(store.navigation == PanelNavigation(listSelection: "c", selectedID: nil))
    }

    @Test func undoRestoresTheSelection() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let (store, _) = await ready(defaults: defaults)
        store.settleSelection()
        #expect(store.listSelection == "a")
        store.close("a", .done)
        #expect(store.listSelection == "b")
        store.undo()
        #expect(store.listSelection == "a")
        #expect(store.items.map(\.id) == ["a", "b", "c"])
        #expect(store.undoInfo == nil)
    }

    @Test func repeatedUndoWalksBack() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let clock = TestClock()
        let (store, _) = await ready(clock: clock, defaults: defaults)
        store.close("a", .done)
        store.close("b", .declined)
        #expect(store.undoInfo == UndoInfo(verdict: .declined, title: "Ask b", deadline: clock.now.addingTimeInterval(10), more: 1))
        store.undo()
        #expect(store.undoInfo?.title == "Ask a")
        #expect(store.undoInfo?.more == 0)
        store.undo()
        #expect(store.undoInfo == nil)
    }

    @Test func undoOutsideTheFilterLeavesTheSelection() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let (store, _) = await ready([item("a", created: stamp(minutesAgo: 10)),
                                      item("x", project: "Northwind", created: stamp(minutesAgo: 20))], defaults: defaults)
        store.setFilter("Acme")
        store.settleSelection()
        store.open("x")
        store.close("x", .done)
        #expect(store.navigation == PanelNavigation(listSelection: "a", selectedID: "a"))
        store.undo()
        #expect(store.navigation == PanelNavigation(listSelection: "a", selectedID: "a"))
        #expect(store.hiddenCount.total == 1)
    }

    @Test func aFailedSendPostsANoticeAndTheAskReappears() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let clock = TestClock()
        let (store, fake) = await ready(clock: clock, defaults: defaults)
        await fake.failNext(QueueError.unreachable("timed out"), on: "resolve")
        store.close("a", .done)
        clock.advance(11)
        store.sendDue()
        #expect(await eventually { store.notice != nil })
        #expect(store.notice == .actionFailed(verdict: .done, id: "a", title: "Ask a", reason: "timed out"))
        #expect(await eventually { store.items.contains { $0.id == "a" } })

        await store.performNoticeAction()
        #expect(await eventually { await fake.count("resolve a done") == 2 })
        #expect(store.notice == nil)
    }

    @Test func aSentCloseCallsTheCleanUpHook() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let clock = TestClock()
        let (store, _) = await ready(clock: clock, defaults: defaults)
        var sent: [String] = []
        store.onCloseSent = { sent.append($0) }
        store.close("a", .done)
        clock.advance(11)
        store.sendDue()
        #expect(await eventually { sent == ["a"] })
    }

    @Test func aFailedReopenPostsANotice() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let store = Store(defaults: defaults.defaults)
        let fake = FakeQueueSource(items: [item("a", created: stamp(minutesAgo: 10))])
        await fake.setClosed([closed(item("c", created: stamp(minutesAgo: 90)))])
        await start(store, fake)
        await fake.failNext(QueueError.unreachable("timed out"), on: "reopen")
        await store.reopen("c")
        #expect(store.notice == .reopenFailed(id: "c", title: "Ask c", reason: "timed out"))
        await store.performNoticeAction()
        #expect(await eventually { store.items.contains { $0.id == "c" } })
    }

    @Test func aReopenedAskStaysOpenInPlace() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let store = Store(defaults: defaults.defaults)
        let fake = FakeQueueSource(items: [item("a", created: stamp(minutesAgo: 10))])
        await fake.setClosed([closed(item("c", created: stamp(minutesAgo: 90)))])
        await start(store, fake)
        var announced: [String] = []
        store.onAnnounce = { announced.append($0) }
        store.open("c")
        await store.reopen("c")
        #expect(store.selectedID == "c")
        #expect(store.item(for: "c")?.status == "open")
        #expect(announced == ["Ask reopened"])
    }

    @Test func quitStillFlushesHeldCloses() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let (store, fake) = await ready(defaults: defaults)
        store.close("a", .done)
        await store.sendAllPending()
        #expect(await fake.count("resolve a done") == 1)
    }

    @Test func theSessionClosingTheOpenAskPostsANotice() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let (store, fake) = await ready(defaults: defaults)
        store.open("a")
        #expect(await eventually { store.details["a"] != nil })
        await fake.setItems(Array(abc.dropFirst()))
        await store.refresh()
        #expect(store.notice == .sessionClosed(id: "a"))
        #expect(store.details["a"] != nil)
        await store.performNoticeAction()
        #expect(store.selectedID == "b")
    }

    @Test func aSwapKeepsTheOpenAskWhenTheNewSourceHasIt() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let (store, _) = await ready(defaults: defaults)
        store.open("a")
        await start(store, FakeQueueSource(items: abc), identity: mailboxIdentity)
        #expect(store.selectedID == "a")
        #expect(store.notice == nil)
        await start(store, FakeQueueSource(items: [item("z", created: stamp(minutesAgo: 5))]), identity: localIdentity)
        #expect(store.selectedID == nil)
        #expect(store.notice == .settingsReloaded)
    }

    @Test func aSwapToNoSourceClosesTheOpenAsk() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let (store, _) = await ready(defaults: defaults)
        store.open("a")
        store.swap(to: nil, identity: SourceIdentity(key: SourceKey.none, mailbox: nil), pollSeconds: 15)
        #expect(store.selectedID == nil)
        #expect(store.notice == .settingsReloaded)
    }

    @Test func offlineWithACachedListSaysSoOnceAndAGoodListClearsIt() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let clock = TestClock()
        let (store, fake) = await ready(clock: clock, defaults: defaults)
        let since = ClockText.time(clock.now)
        clock.advance(60)
        await fake.failNext(QueueError.unreachable("down"), on: "list")
        await store.refresh()
        #expect(store.notice == .offlineCached(since: since))
        #expect(store.items.map(\.id) == ["a", "b", "c"])
        await fake.failNext(QueueError.unreachable("down"), on: "list")
        await store.refresh()
        #expect(store.notice == .offlineCached(since: since))

        await store.refresh()
        #expect(store.notice == nil)
        store.post(.settingsReloaded)
        await store.refresh()
        #expect(store.notice == .settingsReloaded)
    }

    @Test func oneNoticeAtATime() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let (store, _) = await ready(defaults: defaults)
        store.post(.storeFailed(reason: "full"))
        store.post(.settingsReloaded)
        #expect(store.notice == .settingsReloaded)
        store.dismissNotice()
        #expect(store.notice == nil)
    }
}
