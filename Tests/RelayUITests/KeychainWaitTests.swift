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
    private func acceptedOnDisk(_ ask: (item: WireItem, detail: AskDetail),
                                identity: SourceIdentity = localIdentity) throws -> (MemorySecretStore, URL) {
        let secrets = MemorySecretStore(), url = reviewsURL()
        let seal = try ReviewSeal.loadOrCreate(secrets, file: url)
        let two = ask.detail.revisions[1].stamp
        let record = ReviewRecord(accepted: two, seen: two,
                                  pins: Dictionary(uniqueKeysWithValues: ask.detail.revisions.map { ($0.rev, $0.hash) }))
        try PrivateFile.write(ReviewStore.sealed(records: [ReviewStore.key(sourceKey: identity.key, id: "a"): record],
                                                 sealKey: seal), to: url)
        return (secrets, url)
    }

    private func heldStore(_ defaults: TestDefaults, _ secrets: MemorySecretStore, _ url: URL) -> Store {
        Store(defaults: defaults.defaults, now: { fixedNow },
              reviews: ReviewPersistence(secrets: secrets, url: url, keychain: KeychainQueue(label: "test.held")))
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

        // The queue is there; every ask with a history is locked and says why, rev 1 too: its
        // pins aren't read yet, so a swapped rev 1 couldn't be told apart.
        #expect(store.items.map(\.id).sorted() == ["a", "b"])
        #expect(store.reviewState("a") == .waitingForKeychain(current: two.detail.revisions[1].stamp))
        #expect(store.reviewState("b") == .waitingForKeychain(current: one.detail.revisions[0].stamp))
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
        #expect(store.reviewState("b") == .current(one.detail.revisions[0].stamp))
    }

    /// Fail closed while the records are read: on a Pond, every ask is locked (one with a
    /// history, rev 1 alone, and one with none on a Pond that serves corrections), and copy,
    /// answers, replies, ticks, Done and reports are refused. The list and the detail still show.
    @Test func whileTheReadWaitsEveryPondAskIsLocked() async throws {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        var asking = idSteps(2)
        asking.steps[1].question = Question(prompt: "Env?", choices: ["A", "B"])
        asking.reply = ReplySpec(prompt: "Anything?")
        let two = revised("a", [asking, idSteps(2)])
        let one = revised("b", [idSteps(2, id: "b")])
        var plain = item("c", created: stamp(minutesAgo: 5), steps: 1)
        plain.payload.instructable?.steps[0].code = "run c"
        let (secrets, url) = try acceptedOnDisk(two, identity: mailboxIdentity)
        defer { try? FileManager.default.removeItem(at: url) }
        secrets.holdReads()
        defer { secrets.releaseReads() }
        let store = heldStore(defaults, secrets, url)
        let fake = FakeQueueSource(items: [two.item, one.item, plain],
                                   details: ["a": two.detail, "b": one.detail, "c": AskDetail(item: plain, events: [])])
        await start(store, fake, identity: mailboxIdentity)
        store.setPond(PondVersion.semver(SemVer(major: 1, minor: 4, patch: 0)))
        #expect(store.reviewsLoading)
        #expect(store.items.count == 3)

        #expect(store.reviewState("c") == .waitingForKeychain(current: nil))
        for id in ["a", "b", "c"] {
            #expect(store.isContentLocked(id), "\(id)")
            #expect(store.detail(id)?.locked == true, "\(id)")
            #expect(store.detail(id)?.lockBar?.title == "Waiting for Keychain access", "\(id)")
            #expect(!store.canReport(id), "\(id)")
        }
        // The legacy ask still shows its own steps, only locked.
        #expect(store.item(for: "c")?.instructable?.steps.first?.code == "run c")
        #expect(store.copyCode("c", stamp: nil, text: "run c") == .refused)
        #expect(store.copyCode("b", stamp: one.detail.revisions[0].stamp, text: "run 1") == .refused)
        store.open("a")
        store.close("a", .done)
        store.close("c", .done)
        #expect(!store.pending.contains("a"))
        #expect(!store.pending.contains("c"))
        store.answerDrafts["a"] = ["2": .picked(["A"])]
        #expect(!(await store.sendAnswers("a")))
        store.drafts["c"] = "hello"
        #expect(!(await store.sendReply("c")))
        store.toggleTick("1", in: "b")
        #expect(store.ticks(for: "b").isEmpty)
        #expect(await fake.count("resolve") == 0)
        #expect(await fake.count("answer") == 0)
        #expect(await fake.count("reply") == 0)

        // Once read, the gate runs again: rev 1 and the legacy ask unlock, the accepted
        // correction is current.
        secrets.releaseReads()
        await store.reviewsLoaded()
        #expect(store.reviewState("a") == .current(two.detail.revisions[1].stamp))
        #expect(store.reviewState("b") == .current(one.detail.revisions[0].stamp))
        #expect(store.reviewState("c") == .legacy)
        #expect(store.copyCode("c", stamp: nil, text: "run c") == .copied)
    }

    /// A pin on disk that the served history breaks shows as soon as the records are read.
    @Test func aPinMismatchFoundAfterTheReadLocksTheAskForReview() async throws {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let seen = revised("a", [idSteps(3), idSteps(4)])
        let (secrets, url) = try acceptedOnDisk(seen, identity: mailboxIdentity)
        defer { try? FileManager.default.removeItem(at: url) }
        // The Pond now serves another rev 2 than the one this Mac pinned.
        let swapped = revised("a", [idSteps(3), idSteps(4, codes: [4: "run evil"])])
        secrets.holdReads()
        defer { secrets.releaseReads() }
        let store = heldStore(defaults, secrets, url)
        await start(store, FakeQueueSource(items: [swapped.item], details: ["a": swapped.detail]), identity: mailboxIdentity)
        _ = store.detail("a")
        #expect(store.reviewState("a") == .waitingForKeychain(current: swapped.detail.revisions[1].stamp))
        #expect(store.copyCode("a", stamp: swapped.detail.revisions[1].stamp, text: "run evil") == .refused)

        secrets.releaseReads()
        await store.reviewsLoaded()
        #expect(store.reviewState("a") == .historyChanged(.rolledBack))
        #expect(store.detail("a")?.lockBar?.tone == .history)
        #expect(store.copyCode("a", stamp: swapped.detail.revisions[1].stamp, text: "run evil") == .refused)
    }

    /// This Mac's own queue serves no revisions: its plain asks work while the read waits.
    @Test func thisMacsPlainAsksWorkWhileTheReadWaits() async throws {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let secrets = MemorySecretStore(), url = reviewsURL()
        defer { try? FileManager.default.removeItem(at: url) }
        _ = try ReviewSeal.loadOrCreate(secrets, file: url)
        secrets.holdReads()
        defer { secrets.releaseReads() }
        let store = heldStore(defaults, secrets, url)
        var plain = item("c", created: stamp(minutesAgo: 5), steps: 1)
        plain.payload.instructable?.steps[0].code = "run c"
        await start(store, FakeQueueSource(items: [plain], details: ["c": AskDetail(item: plain, events: [])]))
        #expect(store.reviewsLoading)
        #expect(store.reviewState("c") == .legacy)
        #expect(store.copyCode("c", stamp: nil, text: "run c") == .copied)
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
