import Foundation
import RelayCore
import Testing
@testable import RelayUI

/// Stubs, rollbacks and old Ponds on a pinned ask, and "Trust the Pond's History Again" (Task 3.10).
@Suite @MainActor struct HistoryChangeTests {
    private func pinnedRev2(_ defaults: TestDefaults, recorder: ShellRecorder) async -> (Store, FakeQueueSource, AskDetail) {
        let store = await reviewingStore(defaults)
        store.shell = recorder.shell
        let two = revised("a", [idSteps(3), idSteps(4)])
        let fake = FakeQueueSource(items: [two.item], details: ["a": two.detail])
        await start(store, fake)
        markAccepted(store, "a", two.detail.revisions[1].stamp)
        #expect(store.reviewState("a") == .current(two.detail.revisions[1].stamp))
        return (store, fake, two.detail)
    }

    /// The same ask served without its revision, as a stub from a proxy or a rolled-back Pond.
    private func stub(_ detail: AskDetail) -> WireItem {
        var item = detail.item
        item.revision = nil
        item.payload = Payload(instructable: Instructable(v: 1, title: "Ask a", urgency: "today",
                                                          steps: [Step(action: "Update Hook", id: "s1")]))
        return item
    }

    @Test func aPinnedRev2ServedWithoutARevisionIsLockedWithARedNotice() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let recorder = ShellRecorder()
        let (store, fake, detail) = await pinnedRev2(defaults, recorder: recorder)
        let served = stub(detail)
        await fake.setItems([served])
        await fake.setDetail(AskDetail(item: served, events: []))
        await store.refresh()
        store.open("a")

        #expect(store.reviewState("a") == .historyChanged(.missing))
        #expect(store.notice == .historyChanged(id: "a"))
        #expect(store.detail("a")?.reviewAction == .trustHistory)
        #expect(store.queue.rows["a"]?.historyChanged == true)
        // The last verified body stays on screen, locked; not the stub.
        #expect(store.listed.first?.instructable?.steps.count == 4)
        store.close("a", .done)
        #expect(!store.pending.contains("a"))
        store.close("a", .declined)
        #expect(store.pending.contains("a"))
    }

    /// A rev-1 ask (never corrected), seen and pinned on a Pond that serves revisions.
    private func pinnedRev1(_ defaults: TestDefaults, recorder: ShellRecorder) async -> (Store, FakeQueueSource, AskDetail) {
        let store = await reviewingStore(defaults)
        store.shell = recorder.shell
        let one = revised("a", [idSteps(3)])
        let fake = FakeQueueSource(items: [one.item], details: ["a": one.detail])
        await start(store, fake)
        store.setPond(.semver(SemVer(major: 1, minor: 1, patch: 0)))
        #expect(store.reviewState("a") == .current(one.detail.revisions[0].stamp))
        #expect(store.record("a")?.firstBodyHash != nil)
        return (store, fake, one.detail)
    }

    private func withoutRevision(_ detail: AskDetail, payload: Instructable) -> WireItem {
        var item = detail.item
        item.revision = nil
        item.payload = Payload(instructable: payload)
        return item
    }

    @Test func aRev1AskServedWithoutItsRevisionAndAnotherPayloadIsLocked() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let recorder = ShellRecorder()
        let (store, fake, detail) = await pinnedRev1(defaults, recorder: recorder)
        let swapped = withoutRevision(detail, payload: idSteps(3, codes: [2: "rm -rf ~/x"]))
        await fake.setItems([swapped])
        await fake.setDetail(AskDetail(item: swapped, events: []))
        await store.refresh()
        store.open("a")

        #expect(store.reviewState("a") == .historyChanged(.missing))
        #expect(store.detail("a")?.locked == true)
        #expect(store.copyCode("a", stamp: nil, text: "rm -rf ~/x") == .refused)
        #expect(store.copyCode("a", stamp: detail.revisions[0].stamp, text: "run 2") == .refused)
        #expect(recorder.copied.isEmpty)
        #expect(store.listed.first?.instructable?.steps[1].code == "run 2")
        // A rollback to Pond 1.0.0 doesn't unlock a swapped payload either.
        store.setPond(.semver(SemVer(major: 1, minor: 0, patch: 0)))
        #expect(store.reviewState("a") == .historyChanged(.missing))
    }

    @Test func aRollbackTo100ServingTheVerifiedRev1StaysUsable() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let recorder = ShellRecorder()
        let (store, fake, detail) = await pinnedRev1(defaults, recorder: recorder)
        let same = withoutRevision(detail, payload: idSteps(3))
        await fake.setItems([same])
        await fake.setDetail(AskDetail(item: same, events: []))
        store.setPond(.semver(SemVer(major: 1, minor: 0, patch: 0)))
        await store.refresh()
        #expect(store.reviewState("a") == .legacy)
        #expect(store.copyCode("a", stamp: nil, text: "run 2") == .copied)
    }

    @Test func aPondBelow110ForAPinnedAskIsHistoryChanged() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let recorder = ShellRecorder()
        let (store, _, _) = await pinnedRev2(defaults, recorder: recorder)
        store.setPond(.semver(SemVer(major: 1, minor: 0, patch: 0)))
        #expect(store.reviewState("a") == .historyChanged(.missing))
        store.setPond(.semver(SemVer(major: 1, minor: 3, patch: 0)))
        #expect(store.reviewState("a").isLocked == false)
    }

    @Test func aRolledBackHistoryIsCaughtByThePins() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let recorder = ShellRecorder()
        let (store, fake, _) = await pinnedRev2(defaults, recorder: recorder)
        // The Pond is restored to a snapshot from before the correction: rev 1 only.
        let one = revised("a", [idSteps(3)])
        await fake.setItems([one.item])
        await fake.setDetail(one.detail)
        await store.refresh()
        #expect(store.reviewState("a") == .historyChanged(.rolledBack))
    }

    @Test func trustingAgainNeedsPresenceAndRepinsWhatIsServed() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let recorder = ShellRecorder()
        let (store, fake, _) = await pinnedRev2(defaults, recorder: recorder)
        let one = revised("a", [idSteps(3)])
        await fake.setItems([one.item])
        await fake.setDetail(one.detail)
        await store.refresh()
        store.open("a")
        #expect(store.notice == .historyChanged(id: "a"))

        recorder.presence = false
        #expect(!(await store.trustHistoryAgain()))
        #expect(store.reviewState("a") == .historyChanged(.rolledBack))

        recorder.presence = true
        await store.performNoticeAction()
        #expect(recorder.presenceAsked == ["trust the Pond's history again", "trust the Pond's history again"])
        #expect(store.reviewState("a") == .current(one.detail.revisions[0].stamp))
        #expect(store.record("a")?.pins == [1: one.detail.revisions[0].hash])
        #expect(store.notice == nil)
        #expect(store.queue.rows["a"]?.historyChanged == false)
    }

    /// The Pond controls the list: an ask it leaves out for a poll and then serves rolled back
    /// is still caught, since a pinned record outlives its absence.
    @Test func anAskHiddenForAPollThenRolledBackIsStillLocked() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let clock = TestClock()
        let store = await reviewingStore(defaults, now: { clock.now })
        let two = revised("a", [idSteps(3), idSteps(4)])
        let other = revised("b", [idSteps(2, id: "b")])
        let fake = FakeQueueSource(items: [two.item, other.item], details: ["a": two.detail])
        await start(store, fake)
        markAccepted(store, "a", two.detail.revisions[1].stamp)

        await fake.setItems([other.item])
        await store.refresh()
        #expect(store.record("a")?.pins[2] == two.detail.revisions[1].hash)

        clock.advance(29 * 86_400)
        let one = revised("a", [idSteps(3)])
        await fake.setItems([one.item, other.item])
        await fake.setDetail(one.detail)
        await store.refresh()
        #expect(store.reviewState("a") == .historyChanged(.rolledBack))
        #expect(store.reviewState("a").isLocked)
    }

    /// A pinned record goes only after 30 days in which the Pond never listed the ask.
    @Test func aPinnedRecordIsDroppedAfterThirtyDaysUnlisted() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let clock = TestClock()
        let store = await reviewingStore(defaults, now: { clock.now })
        let two = revised("a", [idSteps(3), idSteps(4)])
        let other = revised("b", [idSteps(2, id: "b")])
        let fake = FakeQueueSource(items: [two.item, other.item], details: ["a": two.detail])
        await start(store, fake)
        #expect(store.record("a") != nil)

        await fake.setItems([other.item])
        clock.advance(10 * 86_400)
        await store.refresh()
        #expect(store.record("a") != nil)
        clock.advance(21 * 86_400)
        await store.refresh()
        #expect(store.record("a") == nil)
        #expect(store.record("b") != nil)
    }

    /// Trust again re-pins only what verifies now: an ask whose served history fails its own
    /// checks, or isn't loaded, keeps every pin it had.
    @Test func trustingAgainKeepsThePinsOfAHistoryThatFails() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let recorder = ShellRecorder()
        let store = await reviewingStore(defaults)
        store.shell = recorder.shell
        let a = revised("a", [idSteps(3), idSteps(4)])
        let b = revised("b", [idSteps(3, id: "b"), idSteps(4, id: "b")])
        let fake = FakeQueueSource(items: [a.item, b.item], details: ["a": a.detail, "b": b.detail])
        await start(store, fake)
        let pinsB = store.record("b")?.pins
        #expect(pinsB?[2] == b.detail.revisions[1].hash)

        // a is rolled back (it verifies, but breaks its pins); b comes back with a broken hash.
        let one = revised("a", [idSteps(3)])
        var broken = b.item
        broken.revision?.hash = String(repeating: "0", count: 64)
        await fake.setItems([one.item, broken])
        await fake.setDetail(one.detail)
        await store.refresh()
        #expect(store.reviewState("a") == .historyChanged(.rolledBack))
        #expect(store.reviewState("b").isLocked)

        #expect(await store.trustHistoryAgain())
        #expect(store.record("a")?.pins == [1: one.detail.revisions[0].hash])
        #expect(store.record("b")?.pins == pinsB)
        #expect(store.reviewState("b").isLocked)
    }

    @Test func aCorrectionAfterTheOwnerSawTheAskPostsTheCorrectedNoticeOnce() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let store = await reviewingStore(defaults)
        let one = revised("a", [idSteps(3)])
        let fake = FakeQueueSource(items: [one.item], details: ["a": one.detail])
        await start(store, fake)
        store.open("a")
        _ = store.detail("a")   // seen as current
        let two = revised("a", [idSteps(3), idSteps(4)])
        await fake.setItems([two.item])
        await fake.setDetail(two.detail)
        await store.refresh()
        #expect(store.notice == .corrected(id: "a", rev: 2))
        store.dismissNotice()
        await store.refresh()
        #expect(store.notice == nil)
    }
}
