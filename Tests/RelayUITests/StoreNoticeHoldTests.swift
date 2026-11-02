import Foundation
import RelayCore
import Testing
@testable import RelayUI

private let ab = [item("a", created: stamp(minutesAgo: 10)), item("b", created: stamp(minutesAgo: 20))]

/// A transient Notice ("This ask is no longer open.") goes on its own; one that asks
/// something of the owner stays until ✕ or its action.
@Suite @MainActor struct StoreNoticeHoldTests {
    private func ready(_ gate: SleepGate, defaults: TestDefaults) async -> Store {
        let store = Store(defaults: defaults.defaults, sleep: { await gate.wait($0) })
        await start(store, FakeQueueSource(items: ab))
        return store
    }

    @Test func aTransientNoticeGoesAfterTheHold() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let gate = SleepGate()
        let store = await ready(gate, defaults: defaults)
        store.post(.noLongerOpen(id: "gone", canShowClosed: false))
        #expect(await eventually { await gate.waiting == 1 })
        #expect(await gate.durations == [.seconds(DS.Motion.noticeHold)])
        #expect(store.notice != nil)
        await gate.release(0)
        #expect(await eventually { store.notice == nil })
    }

    @Test func anErrorNoticeStays() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let gate = SleepGate()
        let store = await ready(gate, defaults: defaults)
        store.post(.storeFailed(reason: "disk full"))
        for _ in 0..<20 { await Task.yield() }
        #expect(await gate.waiting == 0)
        #expect(store.notice == .storeFailed(reason: "disk full"))
    }

    @Test func openingAnAskClearsATransientNotice() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let store = await ready(SleepGate(), defaults: defaults)
        store.post(.noLongerOpen(id: "gone", canShowClosed: false))
        store.open("a")
        #expect(store.notice == nil)
    }

    @Test func anOlderTimerDoesNotClearANewerNotice() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let gate = SleepGate()
        let store = await ready(gate, defaults: defaults)
        store.post(.noLongerOpen(id: "gone", canShowClosed: false))
        #expect(await eventually { await gate.waiting == 1 })
        store.post(.storeFailed(reason: "disk full"))
        await gate.release(0)
        for _ in 0..<20 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(30))
        #expect(store.notice == .storeFailed(reason: "disk full"))
    }

    @Test func onlyReportNoticesAreTransient() {
        #expect(PanelNotice.noLongerOpen(id: "x", canShowClosed: true).isTransient)
        #expect(PanelNotice.settingsReloaded.isTransient)
        #expect(PanelNotice.mailboxUpToDate(level: 4).isTransient)
        #expect(!PanelNotice.sessionClosed(id: "x").isTransient)
        #expect(!PanelNotice.offlineCached(since: "10:42").isTransient)
        #expect(!PanelNotice.storeFailed(reason: "x").isTransient)
    }
}

private actor SleepGate {
    private var continuations: [CheckedContinuation<Void, Never>?] = []
    private(set) var durations: [Duration] = []
    var waiting: Int { continuations.count }
    func wait(_ duration: Duration) async {
        durations.append(duration)
        await withCheckedContinuation { continuations.append($0) }
    }
    func release(_ index: Int) {
        continuations[index]?.resume()
        continuations[index] = nil
    }
}
