import Foundation
import RelayCore
import Testing
@testable import RelayUI

@Suite @MainActor struct StoreLinkTests {
    @Test func anAskInTheQueueIsOpen() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let store = Store(defaults: defaults.defaults)
        let fake = FakeQueueSource(items: [item("a", created: stamp(minutesAgo: 10))])
        await start(store, fake)
        let lists = await fake.count("list")
        #expect(await store.checkLink("a") == .open)
        #expect(await fake.count("list") == lists)
    }

    @Test func aHeldBackAskIsClosed() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let store = Store(defaults: defaults.defaults)
        let fake = FakeQueueSource(items: [item("a", created: stamp(minutesAgo: 10))])
        await start(store, fake)
        store.close("a", .done)
        #expect(await store.checkLink("a") == .closed)
    }

    @Test func noSourceIsUnknownAndDoesNotUseUpTheRefresh() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let store = Store(defaults: defaults.defaults)
        #expect(await store.checkLink("a") == .unknown)
        // The check without a source didn't start the 5-second throttle: the first
        // check after the swap still lists.
        let fake = FakeQueueSource(items: [item("b", created: stamp(minutesAgo: 10))])
        await start(store, fake)
        let lists = await fake.count("list")
        #expect(await store.checkLink("a") == .closed)
        #expect(await fake.count("list") == lists + 1)
    }

    @Test func aReachableSourceWithoutTheAskIsClosed() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let store = Store(defaults: defaults.defaults)
        let fake = FakeQueueSource(items: [item("b", created: stamp(minutesAgo: 10))])
        await start(store, fake)
        #expect(await store.checkLink("a") == .closed)
    }

    @Test func anAskPostedSinceTheLastListIsOpen() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let store = Store(defaults: defaults.defaults)
        let fake = FakeQueueSource(items: [item("b", created: stamp(minutesAgo: 10))])
        await start(store, fake)
        await fake.setItems([item("a", created: stamp(minutesAgo: 1)), item("b", created: stamp(minutesAgo: 10))])
        #expect(await store.checkLink("a") == .open)
    }

    @Test func aSecondCheckWithinFiveSecondsIsUnknown() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let store = Store(defaults: defaults.defaults)
        let fake = FakeQueueSource(items: [item("b", created: stamp(minutesAgo: 10))])
        await start(store, fake)
        #expect(await store.checkLink("a") == .closed)
        let lists = await fake.count("list")
        #expect(await store.checkLink("a") == .unknown)
        #expect(await fake.count("list") == lists)
    }

    @Test func aFailingListIsUnknown() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let store = Store(defaults: defaults.defaults)
        let fake = FakeQueueSource(items: [item("b", created: stamp(minutesAgo: 10))])
        await start(store, fake)
        await fake.failNext(QueueError.unreachable("offline"), on: "list")
        #expect(await store.checkLink("a") == .unknown)
    }
}
