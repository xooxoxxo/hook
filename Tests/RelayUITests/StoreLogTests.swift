import Foundation
@testable import RelayCore
import Testing
@testable import RelayUI

/// The Store writes screens and actions to Hook's log by name only: never an id or a title.
@Suite @MainActor struct StoreLogTests {
    private let abc = [item("a", created: stamp(minutesAgo: 10), steps: 2), item("b", created: stamp(minutesAgo: 20)),
                       item("c", created: stamp(minutesAgo: 30))]

    /// The lines `body` writes, without their timestamps.
    private func logged(_ body: () async -> Void) async -> [String] {
        let dir = FileManager.default.temporaryDirectory.appending(path: "hook-store-log-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = RollingLog(directory: dir, now: { Date() })
        await HookLog.withLog(log) { await body() }
        return log.tail(100).map { String($0.drop(while: { $0 != " " }).dropFirst()) }
    }

    @Test func openingAnAskAndGoingBackLogTheDetailThenTheQueue() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let lines = await logged {
            let store = Store(defaults: defaults.defaults)
            await start(store, FakeQueueSource(items: abc))
            store.open("a")
            store.back()
        }
        #expect(lines == ["screen detail", "screen queue"])
    }

    @Test func showingThePanelLogsTheScreenItShows() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let lines = await logged {
            let store = Store(defaults: defaults.defaults)
            await start(store, FakeQueueSource(items: abc))
            store.panelShown()
            store.panelShown()
        }
        #expect(lines == ["screen queue", "screen queue"])
    }

    @Test func aHiddenPanelLogsNoScreen() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let lines = await logged {
            let store = Store(defaults: defaults.defaults)
            store.shell.isShown = { false }
            await start(store, FakeQueueSource(items: abc))
            store.open("a")
        }
        #expect(lines.isEmpty)
    }

    @Test func doneSkipUndoAndTickAreLoggedByName() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let lines = await logged {
            let store = Store(defaults: defaults.defaults)
            await start(store, FakeQueueSource(items: abc))
            store.toggleTick("1", in: "a")
            store.close("a", .done)
            store.close("b", .declined)
            store.undo()
        }
        #expect(lines == ["action tick", "action done", "action skip", "action undo"])
        #expect(!lines.contains { $0.contains("Ask ") || $0.contains("Acme") })
    }

    @Test func copyLinkIsLoggedAsCopyAndAnIdleCrashSendIsNot() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let lines = await logged {
            let store = Store(defaults: defaults.defaults)
            let fake = FakeQueueSource(items: abc)
            await start(store, fake)
            await store.sendCrashReport()   // no sheet open: nothing happens, nothing is logged
            store.copyLink("a")
        }
        #expect(lines == ["action copy"])
    }
}
