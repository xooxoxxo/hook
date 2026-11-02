import Foundation
import RelayCore
import Testing
@testable import RelayUI

/// Stubs, rollbacks and old Ponds on a pinned ask, and "Trust the Pond's History Again" (Task 3.10).
@Suite @MainActor struct HistoryChangeTests {
    private func pinnedRev2(_ defaults: TestDefaults, recorder: ShellRecorder) async -> (Store, FakeQueueSource, AskDetail) {
        let store = reviewingStore(defaults)
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

    @Test func aCorrectionAfterTheOwnerSawTheAskPostsTheCorrectedNoticeOnce() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let store = reviewingStore(defaults)
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
