import CryptoKit
import Foundation
import RelayCore
import Testing
@testable import RelayUI

/// 0.14: the review seal is read off the main thread. Under ad-hoc signing the first read after
/// an update waits on a Keychain prompt; until it returns the Store runs, the queue lists, and
/// corrections are locked as "Waiting for Keychain access".
@Suite @MainActor struct KeychainWaitTests {
    /// A seal and a sealed record that accepted rev 2 of "a", as an earlier run left them.
    private func acceptedOnDisk(_ ask: (item: WireItem, detail: AskDetail)) throws -> (MemorySecretStore, URL) {
        let secrets = MemorySecretStore(), url = reviewsURL()
        let seal = try ReviewSeal.loadOrCreate(secrets, file: url)
        let two = ask.detail.revisions[1].stamp
        let record = ReviewRecord(accepted: two, seen: two,
                                  pins: Dictionary(uniqueKeysWithValues: ask.detail.revisions.map { ($0.rev, $0.hash) }))
        try PrivateFile.write(ReviewStore.sealed(records: [ReviewStore.key(sourceKey: localIdentity.key, id: "a"): record],
                                                 sealKey: seal), to: url)
        return (secrets, url)
    }

    @Test func theStoreAndTheQueueStartWhileTheSealReadWaits() async throws {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let two = revised("a", [idSteps(3), idSteps(4)])
        let one = revised("b", [idSteps(2, id: "b")])
        let (secrets, url) = try acceptedOnDisk(two)
        defer { try? FileManager.default.removeItem(at: url) }
        secrets.holdReads()
        defer { secrets.releaseReads() }

        // The init returns with the read still waiting on the prompt.
        let store = Store(defaults: defaults.defaults, now: { fixedNow }, reviews: ReviewPersistence(secrets: secrets, url: url, keychain: KeychainQueue(label: "test.held")))
        #expect(await eventually { secrets.waitingReads == 1 })
        #expect(store.reviewsLoading)
        let fake = FakeQueueSource(items: [two.item, one.item], details: ["a": two.detail, "b": one.detail])
        await start(store, fake)

        // The queue is there; the correction is locked and says why; the plain ask isn't locked.
        #expect(store.items.map(\.id).sorted() == ["a", "b"])
        #expect(store.reviewState("a") == .waitingForKeychain(current: two.detail.revisions[1].stamp))
        #expect(store.reviewState("b") == .current(one.detail.revisions[0].stamp))
        let locked = try #require(store.detail("a"))
        #expect(locked.locked)
        #expect(locked.lockBar?.title == "Waiting for Keychain access")
        #expect(locked.lockBar?.action == nil)
        #expect(locked.row.waitingForKeychain)
        #expect(!(await store.acceptRevision("a", stamp: two.detail.revisions[1].stamp)))
        #expect(secrets.waitingReads == 1)

        // The owner answers the prompt: the records fill in and the accepted version is current.
        secrets.releaseReads()
        await store.reviewsLoaded()
        #expect(!store.reviewsLoading)
        #expect(!store.reviewsUnreadable)
        #expect(store.reviewState("a") == .current(two.detail.revisions[1].stamp))
        #expect(store.detail("a")?.locked == false)
        #expect(store.detail("a")?.row.waitingForKeychain == false)
    }

    /// A prompt the owner refuses ends the wait as today's refused read: records unreadable,
    /// the Notice with Reset Review Records…, corrections still locked.
    @Test func aRefusedPromptAfterTheWaitIsTheUnreadableState() async throws {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let two = revised("a", [idSteps(3), idSteps(4)])
        let (secrets, url) = try acceptedOnDisk(two)
        defer { try? FileManager.default.removeItem(at: url) }
        secrets.holdReads()
        let store = Store(defaults: defaults.defaults, now: { fixedNow }, reviews: ReviewPersistence(secrets: secrets, url: url, keychain: KeychainQueue(label: "test.held")))
        await start(store, FakeQueueSource(items: [two.item], details: ["a": two.detail]))
        #expect(store.notice == nil)

        secrets.readError = .unreadable(-128)
        secrets.releaseReads()
        await store.reviewsLoaded()
        #expect(!store.reviewsLoading)
        #expect(store.reviewsUnreadable)
        #expect(store.notice == .reviewRecordsUnreadable)
        if case .pending = store.reviewState("a") {} else { Issue.record("expected pending, got \(store.reviewState("a"))") }
    }

    /// Pins taken while the read waited join the disk's records; nothing is written before.
    @Test func nothingIsWrittenWhileTheReadWaits() async throws {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let two = revised("a", [idSteps(3), idSteps(4)])
        let (secrets, url) = try acceptedOnDisk(two)
        defer { try? FileManager.default.removeItem(at: url) }
        let before = try Data(contentsOf: url)
        secrets.holdReads()
        let store = Store(defaults: defaults.defaults, now: { fixedNow }, reviews: ReviewPersistence(secrets: secrets, url: url, keychain: KeychainQueue(label: "test.held")))
        await start(store, FakeQueueSource(items: [two.item], details: ["a": two.detail]))
        _ = store.detail("a")
        #expect(!store.saveReviewsNow())
        try? await Task.sleep(for: .milliseconds(50))
        #expect(try Data(contentsOf: url) == before)
        secrets.releaseReads()
        await store.reviewsLoaded()
        #expect(store.record("a")?.accepted == two.detail.revisions[1].stamp)
    }
}
