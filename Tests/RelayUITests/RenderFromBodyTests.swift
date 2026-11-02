import Foundation
import RelayCore
import Testing
@testable import RelayUI

/// Render-from-body at ingestion: every list, card and detail path reads the revision the
/// review gate names, never the served payload or an unreviewed body.
@Suite @MainActor struct RenderFromBodyTests {
    @Test func aRevisedItemRendersItsBodyNotItsPayload() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let store = reviewingStore(defaults)
        var says = idSteps(2)
        says.steps[0].action = "B"
        var payload = says
        payload.steps[0].action = "A"
        let ask = revised("a", [says], payload: payload)
        let fake = FakeQueueSource(items: [ask.item], details: ["a": ask.detail])
        await start(store, fake)

        #expect(store.listed.first?.instructable?.steps[0].action == "B")
        #expect(store.item(for: "a")?.instructable?.steps[0].action == "B")
        #expect(store.details["a"]?.item.instructable?.steps[0].action == "B")
        #expect(store.details["a"]?.revisions == [])
        #expect(store.listed.first?.revision == nil)
        #expect(store.reviewState("a") == .current(ask.detail.revisions[0].stamp))
    }

    @Test func aPendingCorrectionPublishesTheAcceptedStepsEverywhere() async throws {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let secrets = MemorySecretStore(), url = reviewsURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let ask = revised("a", [idSteps(3), idSteps(4)])
        let one = ask.detail.revisions[0], two = ask.detail.revisions[1]
        // This Mac accepted rev 1 earlier: a sealed record on disk.
        let key = try ReviewSeal.loadOrCreate(secrets)
        let record = ReviewRecord(accepted: one.stamp, seen: one.stamp, pins: [1: one.hash])
        try ReviewStore.sealed(records: [ReviewStore.key(sourceKey: localIdentity.key, id: "a"): record], sealKey: key)
            .write(to: url)
        let store = reviewingStore(defaults, secrets: secrets, url: url)
        let fake = FakeQueueSource(items: [ask.item], details: ["a": ask.detail])
        await start(store, fake)

        #expect(store.reviewState("a") == .pending(shown: one.stamp, current: two.stamp, baseline: 1))
        #expect(store.listed.first?.instructable?.steps.count == 3)
        #expect(store.details["a"]?.item.instructable?.steps.count == 3)
        #expect(store.queue.rows["a"]?.summary == .steps(done: 0, total: 3))
        let accepted = QueueSnapshot.row(revised("a", [idSteps(3)]).item, ticked: [], hasDraft: false, closedBy: nil)
        #expect(store.queue.rows["a"]?.subline == accepted.subline)
        let snapshot = store.detail("a")
        #expect(snapshot?.model?.nodes.count == 3)
        #expect(snapshot?.stamp == one.stamp)
        #expect(snapshot?.locked == true)
        #expect(snapshot?.reviewAction == .review(current: two.stamp))
        // Every verified stamp is pinned; a locked render marks nothing seen.
        #expect(store.record("a")?.pins == [1: one.hash, 2: two.hash])
        #expect(store.record("a")?.seen == one.stamp)
    }

    @Test func aListItemBeforeItsDetailRendersNoUnreviewedSteps() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let store = reviewingStore(defaults)
        let ask = revised("a", [idSteps(3), idSteps(4, codes: [4: "rm -rf ~/x"])])
        // The detail fetch fails: only the listed (current) revision is at hand.
        let fake = FakeQueueSource(items: [ask.item])
        await fake.failNext(QueueError.unreachable("offline"), on: "get a")
        await start(store, fake)
        #expect(store.reviewState("a").isLocked)
        let shown = store.listed.first?.instructable
        #expect(shown?.steps.isEmpty == true)
        #expect(shown?.title == "Ask a")
    }

    @Test func aBrokenHistoryIsLockedAndRendersNothingNew() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let store = reviewingStore(defaults)
        var ask = revised("a", [idSteps(3), idSteps(4)])
        ask.detail.revisions[1].body = ask.detail.revisions[1].body.replacingOccurrences(of: "run 4", with: "run 5")
        let fake = FakeQueueSource(items: [ask.item], details: ["a": ask.detail])
        await start(store, fake)
        #expect(store.reviewState("a") == .historyChanged(.badHash(2)))
        #expect(store.detail("a")?.reviewAction == .trustHistory)
        #expect(store.listed.first?.instructable?.steps.allSatisfy { $0.code != "run 5" } == true)
    }
}
