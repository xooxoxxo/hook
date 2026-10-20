import Foundation
import RelayCore
import Testing
@testable import RelayUI

@Suite @MainActor struct StoreArrivalTests {
    @Test func aNewAskOnALaterListIsAnnouncedOnce() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let store = Store(defaults: defaults.defaults)
        var announced: [[String]] = []
        store.onNewItems = { announced.append($0.map(\.id)) }
        let fake = FakeQueueSource(items: [item("a", created: stamp(minutesAgo: 10))])
        await start(store, fake, identity: mailboxIdentity)
        #expect(announced.isEmpty)

        await fake.setItems([item("b", created: stamp(minutesAgo: 1)), item("a", created: stamp(minutesAgo: 10))])
        await store.refresh()
        #expect(announced == [["b"]])

        await store.refresh()
        #expect(announced == [["b"]])
    }
}
