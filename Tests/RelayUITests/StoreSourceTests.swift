import Foundation
import RelayCore
import Testing
@testable import RelayUI

@Suite @MainActor struct StoreSourceTests {
    @Test func swapListsTheSourcesItems() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let store = Store(defaults: defaults.defaults)
        let fake = FakeQueueSource(items: [item("a", created: stamp(minutesAgo: 10)), item("b", created: stamp(minutesAgo: 20))])
        await start(store, fake)
        #expect(store.items.map(\.id) == ["a", "b"])
        #expect(store.sourceKey == "local")
        #expect(store.identity == localIdentity)
        #expect(store.reachable)
    }

    @Test func aNewPollIntervalKeepsEverything() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let clock = TestClock()
        let store = Store(defaults: defaults.defaults, now: { clock.now })
        let fake = FakeQueueSource(items: [item("a", created: stamp(minutesAgo: 10)), item("b", created: stamp(minutesAgo: 20))])
        await start(store, fake)
        store.open("a")
        #expect(await eventually { store.details["a"] != nil })
        store.close("b", .done)

        store.setPollInterval(30)

        #expect(store.navigation.selectedID == "a")
        #expect(store.items.map(\.id) == ["a"])
        #expect(store.pending.contains("b"))
        #expect(store.details["a"] != nil)
        #expect(store.sourceKey == "local")
        #expect(await fake.count("resolve") == 0)
    }

    @Test func aSwapFlushesHeldClosesToTheOldSource() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let store = Store(defaults: defaults.defaults)
        let old = FakeQueueSource(items: [item("a", created: stamp(minutesAgo: 10))])
        await start(store, old)
        store.close("a", .done)
        await start(store, FakeQueueSource(), identity: mailboxIdentity)
        #expect(await eventually { await old.count("resolve a done") == 1 })
        #expect(store.sourceKey == mailboxIdentity.key)
        #expect(store.items.isEmpty)
    }

    @Test func noSourceIsNotSetUp() {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let store = Store(defaults: defaults.defaults)
        store.swap(to: nil, identity: SourceIdentity(key: SourceKey.none, mailbox: nil), pollSeconds: 15)
        #expect(store.sourceKey == SourceKey.none)
        #expect(!store.reachable)
        #expect(store.problem == Store.noSourceProblem)
    }
}
