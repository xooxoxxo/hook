import Foundation
import RelayCore
import Testing
@testable import RelayUI

/// Steps added at the end of an open ask: Hook's own check finds a pure append, so the ask stays
/// current and the Store seals it as seen and accepted, with no review and no Touch ID.
@Suite @MainActor struct StoreAppendTests {
    private struct Setup {
        let store: Store
        let fake: FakeQueueSource
        let recorder: ShellRecorder
        let url: URL
        let one: RevisionStamp
    }

    /// Rev 1 (s1…s3), shown and accepted on this Mac.
    private func setUp(_ defaults: TestDefaults) async -> Setup {
        let url = reviewsURL()
        let store = await reviewingStore(defaults, url: url)
        let recorder = ShellRecorder()
        store.shell = recorder.shell
        let one = revised("a", [idSteps(3)])
        let fake = FakeQueueSource(items: [one.item], details: ["a": one.detail])
        await start(store, fake)
        let stamp = one.detail.revisions[0].stamp
        var record = store.record("a") ?? ReviewRecord()
        record.accepted = stamp
        record.seen = stamp
        store.setRecord(record, for: "a")
        store.rerender("a")
        return Setup(store: store, fake: fake, recorder: recorder, url: url, one: stamp)
    }

    /// The Pond serves `ask` in the list and in its detail.
    private func serve(_ s: Setup, _ ask: (item: WireItem, detail: AskDetail)) async {
        await s.fake.setItems([ask.item])
        await s.fake.setDetail(ask.detail)
        await s.store.refresh()
    }

    @Test func appendSealsWithoutPrompt() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let s = await setUp(defaults)
        defer { try? FileManager.default.removeItem(at: s.url) }
        let two = revised("a", [idSteps(3), idSteps(4)], reasons: ["One more check"], acceptedRev: 2)
        await serve(s, two)
        let stamp = two.detail.revisions[1].stamp
        #expect(s.store.reviewState("a") == .current(stamp))
        #expect(s.store.record("a")?.accepted == stamp)
        #expect(s.store.record("a")?.seen == stamp)
        #expect(s.store.record("a")?.changed == [])
        #expect(s.store.record("a")?.added == [])
        #expect(s.recorder.presenceAsked.isEmpty)
        #expect(s.store.detail("a")?.locked == false)
        #expect(s.store.listed.first?.instructable?.steps.count == 4)
        // The Pond already took rev 2 on its own: nothing to send.
        #expect(await s.fake.count("accept") == 0)
        #expect(s.store.record("a")?.pondAcceptPending == false)
    }

    @Test func appendSendsAcceptWhenPondBehind() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let s = await setUp(defaults)
        defer { try? FileManager.default.removeItem(at: s.url) }
        let two = revised("a", [idSteps(3), idSteps(4)], acceptedRev: 1)
        await serve(s, two)
        #expect(await eventually { await s.fake.count("accept a @2") == 1 })
        #expect(await eventually { s.store.record("a")?.pondAcceptPending == false })
        #expect(s.recorder.presenceAsked.isEmpty)
        // Once: another poll of the same revision sends nothing more.
        await s.store.refresh()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await s.fake.count("accept") == 1)
    }

    @Test func aFailedAppendAcceptStaysPendingForTheNextAct() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let s = await setUp(defaults)
        defer { try? FileManager.default.removeItem(at: s.url) }
        await s.fake.failNext(QueueError.unreachable("down"), on: "accept")
        let two = revised("a", [idSteps(3), idSteps(4)], acceptedRev: 1)
        await serve(s, two)
        #expect(await eventually { await s.fake.count("accept a @2") == 1 })
        try? await Task.sleep(for: .milliseconds(50))
        #expect(s.store.record("a")?.accepted == two.detail.revisions[1].stamp)
        #expect(s.store.record("a")?.pondAcceptPending == true)
        #expect(s.store.reviewState("a") == .current(two.detail.revisions[1].stamp))
    }

    /// The list serves rev 3 while the detail still holds rev 1: locked, but with no review
    /// action, until the detail arrives and the check can run.
    @Test func appendViaListThenDetailUnlocks() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let s = await setUp(defaults)
        defer { try? FileManager.default.removeItem(at: s.url) }
        let three = revised("a", [idSteps(3), idSteps(4), idSteps(5)], acceptedRev: 1)
        await s.fake.failNext(QueueError.unreachable("down"), on: "get a")
        await s.fake.setItems([three.item])
        await s.store.refresh()
        #expect(s.store.reviewState("a").isLocked)
        #expect(s.store.detail("a")?.locked == true)
        #expect(s.store.detail("a")?.reviewAction == nil)
        #expect(s.store.detail("a")?.lockBar?.action == nil)
        if case .corrected? = s.store.notice { Issue.record("no Review Changes Notice while the append is checked") }
        s.store.startReview("a")
        #expect(!s.store.isReviewing("a"))

        await s.fake.setDetail(three.detail)
        await s.store.refreshDetail("a")
        let stamp = three.detail.revisions[2].stamp
        #expect(s.store.reviewState("a") == .current(stamp))
        #expect(s.store.detail("a")?.locked == false)
        #expect(s.store.record("a")?.accepted == stamp)
        #expect(s.recorder.presenceAsked.isEmpty)
    }

    /// A correction the list serves alone still shows its review once its body is known to differ.
    @Test func aCorrectionStillShowsItsReview() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let s = await setUp(defaults)
        defer { try? FileManager.default.removeItem(at: s.url) }
        let two = revised("a", [idSteps(3), idSteps(3, codes: [2: "run 2 --fixed"])], acceptedRev: 1)
        await serve(s, two)
        let stamp = two.detail.revisions[1].stamp
        #expect(s.store.reviewState("a") == .pending(shown: s.one, current: stamp, baseline: 1))
        #expect(s.store.detail("a")?.reviewAction == .review(current: stamp))
        #expect(s.store.record("a")?.accepted == s.one)
        #expect(await s.fake.count("accept") == 0)
    }

    /// The markers start after the last revision that wasn't an append (the one the owner reviewed).
    @Test func appendMarkersStartAfterTheReviewedRevision() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let s = await setUp(defaults)
        defer { try? FileManager.default.removeItem(at: s.url) }
        let answer = Event(seq: 1, itemId: "a", kind: "answer", actor: "owner", text: "{}",
                           at: "2026-10-29T10:00:30+00:00", rev: 1)
        let three = revised("a", [idSteps(3), idSteps(4), idSteps(5)], reasons: ["After your answer", "And one more"],
                            acceptedRev: 3, events: [answer])
        await serve(s, three)
        let markers = s.store.appendMarkers("a")
        #expect(markers.map(\.rev) == [2, 3])
        #expect(markers.map(\.afterAnswer) == [true, false])
        #expect(markers.map(\.firstStepID) == ["s4", "s5"])
        #expect(markers.map(\.note) == ["After your answer", "And one more"])

        #expect(s.store.appendMarkers("nope").isEmpty)
    }

    /// A correction the owner accepted at rev 2, then an append at rev 3: one marker.
    @Test func anAppendAfterAnAcceptedCorrectionHasOneMarker() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let url = reviewsURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = await reviewingStore(defaults, url: url)
        let fixed = idSteps(3, codes: [2: "run 2 --fixed"])
        var withFix = idSteps(4, codes: [2: "run 2 --fixed"])
        withFix.steps[3].id = "r3-1"
        let ask = revised("a", [idSteps(3), fixed, withFix], acceptedRev: 2)
        let fake = FakeQueueSource(items: [ask.item], details: ["a": ask.detail])
        await start(store, fake)
        #expect(store.reviewState("a").isLocked)
        markAccepted(store, "a", ask.detail.revisions[1].stamp)
        await store.refreshDetail("a")
        #expect(store.reviewState("a") == .current(ask.detail.revisions[2].stamp))
        #expect(store.appendMarkers("a").map(\.rev) == [3])
        #expect(store.appendMarkers("a").first?.firstStepID == "r3-1")
        #expect(store.appendMarkers("a").first?.addedTopLevel == 1)
    }
}

/// The owner's Done refused because the session added steps or may still add them: the words
/// the plan gives, no Retry, and the detail fetched again.
@Suite @MainActor struct StoreAppendDoneTests {
    @Test(arguments: [(QueueError.stepsAdded(rev: 2, hash: "abc"), "New steps were added. Open the ask to see them."),
                      (QueueError.waitingForSteps(until: fixedNow.addingTimeInterval(300)), "Waiting for next steps…")])
    func aRefusedDoneSaysWhy(_ error: QueueError, _ words: String) async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let clock = TestClock()
        let store = Store(defaults: defaults.defaults, now: { clock.now })
        let fake = FakeQueueSource(items: [item("a", created: stamp(minutesAgo: 5), steps: 2)])
        await start(store, fake)
        await fake.failNext(error, on: "resolve")
        store.close("a", .done)
        let loads = await fake.count("get a")
        clock.advance(11)
        store.sendDue()
        #expect(await eventually { store.notice == .deliveryFailed(reason: words) })
        #expect(store.notice?.text == words)
        #expect(store.notice?.actionTitle == nil)
        #expect(store.items.map(\.id) == ["a"])
        #expect(await eventually { await fake.count("get a") > loads })
        try? await Task.sleep(for: .milliseconds(30))
        #expect(await fake.count("resolve") == 1)
    }
}
