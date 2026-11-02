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
        let store = reviewingStore(defaults, secrets: secrets, url: url)
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
        let saved = ReviewStore.load(from: url, sealKey: try! ReviewSeal.loadOrCreate(secrets))
        #expect(!saved.tampered)
        #expect(saved.records[ReviewStore.key(sourceKey: localIdentity.key, id: "a")]?.seen == one.detail.revisions[0].stamp)
    }

    @Test func aRefusedSealKeyKeepsCorrectedAsksLockedAndWritesNothing() async throws {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let url = reviewsURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("{\"v\":1,\"records\":{}}".utf8).write(to: url)
        let before = try Data(contentsOf: url)
        let secrets = MemorySecretStore()
        secrets.readError = .unreadable(-128)
        let store = reviewingStore(defaults, secrets: secrets, url: url)
        let two = revised("a", [idSteps(3), idSteps(4)])
        let fake = FakeQueueSource(items: [two.item], details: ["a": two.detail])
        await start(store, fake)

        #expect(store.reviewsUnreadable)
        #expect(store.notice == .reviewRecordsUnreadable)
        #expect(store.reviewState("a").isLocked)
        _ = store.detail("a")
        #expect(secrets.writes == 0)
        #expect(secrets.peek(.reviewSeal) == nil)
        #expect(!store.saveReviewsNow())
        try? await Task.sleep(for: .milliseconds(50))
        #expect(try Data(contentsOf: url) == before)
    }

    @Test func aTamperedRecordIsDroppedWithANotice() async throws {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let url = reviewsURL(), secrets = MemorySecretStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let two = revised("a", [idSteps(3), idSteps(4)])
        // A record sealed under another key: as if written by hand.
        let forged = ReviewRecord(accepted: two.detail.revisions[1].stamp)
        try ReviewStore.sealed(records: [ReviewStore.key(sourceKey: localIdentity.key, id: "a"): forged],
                               sealKey: SymmetricKey(size: .bits256)).write(to: url)
        let store = reviewingStore(defaults, secrets: secrets, url: url)
        let fake = FakeQueueSource(items: [two.item], details: ["a": two.detail])
        await start(store, fake)
        #expect(store.notice == .reviewRecordsChanged)
        #expect(store.reviewState("a").isLocked)
    }

    @Test func aLaterNoticeKeepsTheReviewEntryPoint() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let store = reviewingStore(defaults)
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
}
