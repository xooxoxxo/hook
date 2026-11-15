import Foundation
import RelayCore
import Testing
@testable import RelayUI

/// `then: "steps"`: after the owner answers, Done waits for the session's next steps (a new
/// revision) or 10 minutes; Skip always works (Task 20).
@Suite @MainActor struct StoreStepWaitTests {
    /// Rev 1 at 10:00, its step 2 asking "Which region?" with `then: "steps"`.
    private static func body(_ count: Int) -> Instructable {
        var steps = (1...count).map { Step(action: "Step \($0)", code: "run \($0)", id: "s\($0)") }
        steps[1].question = Question(prompt: "Which region?", choices: ["A", "B"],
                                     then: "steps")
        return Instructable(v: 1, title: "Ask a", urgency: "today", steps: steps)
    }

    /// The owner answered step 2 at 10:00:30.
    private static let answer = Event(seq: 1, itemId: "a", kind: "answer", actor: "owner",
                                      text: #"{"step":"2","id":"s2","picked":["A"]}"#, at: "2026-10-29T10:00:30+00:00")

    private struct Setup {
        let store: Store
        let fake: FakeQueueSource
        let clock: TestClock
        let sleeps: SleepLog
        let url: URL
    }

    @MainActor final class SleepLog {
        var durations: [Duration] = []
    }

    private func setUp(_ defaults: TestDefaults, served: ServedStepWait? = nil,
                       capabilities: PondCapabilities? = nil) async -> Setup {
        let clock = TestClock()
        clock.now = Timestamp.date("2026-10-29T10:00:45+00:00")!
        let sleeps = SleepLog()
        let url = reviewsURL()
        let store = Store(defaults: defaults.defaults, now: { clock.now },
                          timeoutSleep: { duration in await MainActor.run { sleeps.durations.append(duration) } },
                          reviews: ReviewPersistence(secrets: MemorySecretStore(), url: url))
        await store.reviewsLoaded()
        var ask = revised("a", [Self.body(3)], events: [Self.answer])
        ask.item.stepWait = served
        ask.detail = AskDetail(item: ask.item, events: ask.detail.events, revisions: ask.detail.revisions)
        let fake = FakeQueueSource(items: [ask.item], details: ["a": ask.detail])
        await start(store, fake)
        // After the swap, which forgets the last Pond's capabilities.
        if let capabilities { store.setPondCapabilities(capabilities) }
        await store.refreshDetail("a")
        return Setup(store: store, fake: fake, clock: clock, sleeps: sleeps, url: url)
    }

    @Test func doneOffWhileWaiting() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let s = await setUp(defaults)
        defer { try? FileManager.default.removeItem(at: s.url) }
        let snapshot = s.store.detail("a")
        #expect(snapshot?.stepWait?.path == "2")
        #expect(snapshot?.stepWait?.until == Timestamp.date("2026-10-29T10:10:30+00:00"))
        #expect(snapshot?.doneEnabled == false)
        #expect(snapshot?.discardEnabled == false)
        #expect(!s.store.doneAllowed("a"))
        #expect(s.store.queue.rows["a"]?.doneBlocked == true)
        s.store.close("a", .done)
        #expect(s.store.items.map(\.id) == ["a"])
    }

    @Test func skipOnWhileWaiting() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let s = await setUp(defaults)
        defer { try? FileManager.default.removeItem(at: s.url) }
        #expect(s.store.detail("a")?.stepWait != nil)
        s.store.close("a", .declined)
        #expect(s.store.items.isEmpty)
    }

    @Test func stepWaitEndsOnTimer() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let s = await setUp(defaults)
        defer { try? FileManager.default.removeItem(at: s.url) }
        // One re-render scheduled at `until`, 9 min 45 s away.
        #expect(await eventually { s.sleeps.durations.contains(.seconds(585)) })
        #expect(s.store.detail("a")?.doneEnabled == false)
        s.clock.advance(585)
        let lists = await s.fake.count("list")
        #expect(s.store.detail("a")?.stepWait == nil)
        #expect(s.store.detail("a")?.doneEnabled == true)
        #expect(s.store.doneAllowed("a"))
        #expect(await s.fake.count("list") == lists)
    }

    @Test func stepWaitEndsOnAppend() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let s = await setUp(defaults)
        defer { try? FileManager.default.removeItem(at: s.url) }
        #expect(s.store.stepWaitUntil["a"] != nil)
        // Rev 2 at 10:01 adds step 4: later than the answer, so the wait is over.
        let two = revised("a", [Self.body(3), Self.body(4)], reasons: ["One more"], events: [Self.answer])
        await s.fake.setItems([two.item])
        await s.fake.setDetail(two.detail)
        await s.store.refresh()
        #expect(s.store.detail("a")?.stepWait == nil)
        #expect(s.store.detail("a")?.doneEnabled == true)
        #expect(s.store.stepWaitUntil["a"] == nil)
    }

    /// A deep link fetches the ask itself: an ask mid-wait still gets its timer.
    @Test func aDeepLinkSchedulesTheTimer() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let s = await setUp(defaults)
        defer { try? FileManager.default.removeItem(at: s.url) }
        s.store.stepWaitTimers.removeValue(forKey: "a")?.cancel()
        s.store.stepWaitUntil["a"] = nil
        await s.store.focus("a")
        #expect(s.store.stepWaitUntil["a"] == Timestamp.date("2026-10-29T10:10:30+00:00"))
    }

    /// A Pond that lists appendSteps decides from the single-item route: no `stepWait`, no wait.
    @Test func aPondThatServesWaitsDecides() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let lists = PondCapabilities(version: .semver(SemVer(major: 1, minor: 9, patch: 0)), features: ["appendSteps"])
        let none = await setUp(defaults, capabilities: lists)
        defer { try? FileManager.default.removeItem(at: none.url) }
        #expect(none.store.detail("a")?.stepWait == nil)

        let other = TestDefaults()
        defer { other.drop() }
        let served = ServedStepWait(id: "s2", path: "2", until: "2026-10-29T10:03:00+00:00")
        let waits = await setUp(other, served: served, capabilities: lists)
        defer { try? FileManager.default.removeItem(at: waits.url) }
        #expect(waits.store.detail("a")?.stepWait?.until == Timestamp.date("2026-10-29T10:03:00+00:00"))
    }
}
