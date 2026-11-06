import Foundation
import RelayCore
import Testing
@testable import RelayUI
@testable import RelayUIMac

/// The inline review (Direction B): Show Changes, the page the Store builds, a newer version
/// during the review, Use Version N ending it, and the locked detail's tags and bars.
@Suite @MainActor struct InlineReviewTests {
    private func pendingStore(_ defaults: TestDefaults, recorder: ShellRecorder)
        async -> (Store, FakeQueueSource, AskDetail) {
        let store = await reviewingStore(defaults)
        store.shell = recorder.shell
        let two = revised("a", [idSteps(3), idSteps(4, codes: [2: "run two --all"])])
        let fake = FakeQueueSource(items: [two.item], details: ["a": two.detail])
        await start(store, fake)
        store.open("a")
        _ = await eventually { store.reviewDiff("a") != nil }
        markAccepted(store, "a", two.detail.revisions[0].stamp)
        return (store, fake, two.detail)
    }

    @Test func showChangesReviewsTheCurrentVersion() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let (store, _, detail) = await pendingStore(defaults, recorder: ShellRecorder())
        #expect(!store.isReviewing("a"))
        store.startReview("a")
        #expect(store.isReviewing("a"))
        let page = store.reviewPage("a")
        #expect(page?.target == detail.revisions[1].stamp)
        #expect(page?.steps.map(\.change) == [.same, .changed, .same, .added])
        #expect(page?.needsPresence == true)
        store.endReview("a")
        #expect(!store.isReviewing("a"))
    }

    @Test func aNewerVersionDuringTheReviewIsShownNeverAccepted() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let recorder = ShellRecorder()
        let (store, fake, _) = await pendingStore(defaults, recorder: recorder)
        store.startReview("a")
        let three = revised("a", [idSteps(3), idSteps(4, codes: [2: "run two --all"]), idSteps(5)])
        await fake.setItems([three.item])
        await fake.setDetail(three.detail)
        await store.refresh()
        store.retryDetail("a")
        _ = await eventually { store.reviewState("a") != .current(three.detail.revisions[2].stamp)
            && (try? store.histories["a"]?.get())?.isComplete == true
            && (try? store.histories["a"]?.get())?.current.rev == 3 }
        let page = store.reviewPage("a")
        #expect(page?.target.rev == 2)
        #expect(page?.isStale == true)
        #expect(page?.primaryTitle == "Show Version 3")
        store.startReview("a")
        #expect(store.reviewPage("a")?.target == three.detail.revisions[2].stamp)
        #expect(store.reviewPage("a")?.isStale == false)
        #expect(recorder.presenceAsked.isEmpty)
    }

    @Test func useVersionEndsTheReview() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let recorder = ShellRecorder()
        let (store, fake, detail) = await pendingStore(defaults, recorder: recorder)
        store.startReview("a")
        store.accept("a", stamp: detail.revisions[1].stamp)
        _ = await eventually { store.reviewing["a"] == nil }
        #expect(store.reviewing["a"] == nil)
        #expect(store.reviewState("a") == .current(detail.revisions[1].stamp))
        #expect(await fake.count("accept") == 1)
        #expect(DetailView<Store>.bar(store.detail("a")!, reviewing: store.isReviewing("a")) == .action)
        #expect(recorder.presenceAsked.count == 1)
    }

    /// Use Version N is off while an accept is in flight (Touch ID up, or the Pond call), and a
    /// second press accepts nothing more.
    @Test func useVersionIsOffWhileAnAcceptIsInFlight() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let recorder = ShellRecorder()
        let (store, fake, detail) = await pendingStore(defaults, recorder: recorder)
        let gate = PresenceGate()
        store.shell.confirmPresence = { _ in await gate.wait() }
        store.startReview("a")
        let page = store.reviewPage("a")
        #expect(DetailReviewBar<Store>.primaryEnabled(page: page, accepting: store.isAccepting("a")))
        store.accept("a", stamp: detail.revisions[1].stamp)
        _ = await eventually { gate.waiting }
        #expect(store.isAccepting("a"))
        #expect(!DetailReviewBar<Store>.primaryEnabled(page: page, accepting: store.isAccepting("a")))
        store.accept("a", stamp: detail.revisions[1].stamp)
        #expect(!(await store.acceptRevision("a", stamp: detail.revisions[1].stamp)))
        gate.open(true)
        _ = await eventually { !store.isAccepting("a") }
        #expect(!store.isAccepting("a"))
        #expect(gate.asked == 1)
        #expect(await fake.count("accept") == 1)
        #expect(store.reviewState("a") == .current(detail.revisions[1].stamp))
    }

    /// Skip is in the review bar too: the design says it always works.
    @Test func theReviewBarOffersSkip() async throws {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let (store, _, _) = await pendingStore(defaults, recorder: ShellRecorder())
        store.startReview("a")
        let page = try #require(store.reviewPage("a"))
        #expect(DetailReviewBar<Store>.buttonTitles(page: page) == ["Skip", ReviewPage.notNow, page.primaryTitle])
        #expect(DetailReviewBar<Store>.buttonTitles(page: nil) == ["Skip", ReviewPage.notNow])
    }

    /// The review ends when the ask leaves it another way than Not Now or Use Version N.
    @Test func skipCloseAndReopenEndTheReview() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let (store, fake, detail) = await pendingStore(defaults, recorder: ShellRecorder())
        store.startReview("a")
        store.close("a", .declined)
        #expect(store.reviewing["a"] == nil)

        store.undo()
        store.open("a")
        store.startReview("a")
        #expect(store.isReviewing("a"))
        // Closed from somewhere else: the next list leaves it out, Recently closed has it.
        _ = try? await fake.resolve("a", verdict: .declined, note: nil)
        await store.refresh()
        #expect(store.reviewing["a"] == nil)

        store.reviewing["a"] = detail.revisions[1].stamp
        await store.reopen("a")
        #expect(store.reviewing["a"] == nil)
    }

    @Test func theLockedDetailTagsTheShownVersion() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let (store, _, _) = await pendingStore(defaults, recorder: ShellRecorder())
        let snapshot = store.detail("a")!
        #expect(snapshot.locked)
        #expect(snapshot.changedSteps == ["2": .changed])
        #expect(snapshot.addedSinceShown == 1)
        #expect(DetailSteps<Store>.dims(snapshot.model!.nodes[0], snapshot: snapshot))
        #expect(!DetailSteps<Store>.dims(snapshot.model!.nodes[1], snapshot: snapshot))
        guard case .lock(let bar) = DetailView<Store>.bar(snapshot, reviewing: false) else {
            Issue.record("expected the lock bar")
            return
        }
        #expect(bar.action == ReviewLockBar.showChanges)
        #expect(DetailView<Store>.bar(snapshot, reviewing: true) == .review)
        #expect(DetailView<Store>.barCovers(.corrected(id: "a", rev: 2), snapshot))
        #expect(!DetailView<Store>.barCovers(.corrected(id: "b", rev: 2), snapshot))
    }

    @Test func theNoticesReviewChangesOpensTheReview() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let (store, _, _) = await pendingStore(defaults, recorder: ShellRecorder())
        store.back()
        store.post(.corrected(id: "a", rev: 2))
        await store.performNoticeAction()
        #expect(store.navigation.selectedID == "a")
        #expect(store.isReviewing("a"))
    }

    @Test func aHistoryLockNeverOffersTheReview() {
        var snapshot = GalleryFixtures.detailSteps
        snapshot.review = .historyChanged(.rolledBack)
        guard case .lock(let bar) = DetailView<FixturePanelModel>.bar(snapshot, reviewing: true) else {
            Issue.record("expected the lock bar")
            return
        }
        #expect(bar.tone == .history)
    }

    @Test func theQueueCardLabelsAReviewState() {
        let row = AskRowModel(id: "a", title: "T", project: "P", urgency: Urgency(raw: "today"), created: "",
                              summary: .none, review: .historyChanged(.missing))
        #expect(AskRow.reviewLabel(row) == "Check history")
        let pending = AskRowModel(id: "a", title: "T", project: "P", urgency: Urgency(raw: "today"), created: "",
                                  summary: .none, review: .pending(shown: nil, current: RevisionStamp(rev: 2, hash: "h"),
                                                                   baseline: nil))
        #expect(AskRow.reviewLabel(pending) == "Corrected")
        #expect(AskRow.accessibilityText(row: pending, age: "now").hasSuffix("Corrected"))
    }

    @Test func ownerKeyWords() {
        #expect(OwnerKeyText.grouped("482913") == "482 913")
        #expect(OwnerKeyText.requireNote(required: false, offPending: false, canRequire: false, problem: nil)
                == "Available once two devices are approved, this one among them.")
        #expect(OwnerKeyText.requireNote(required: false, offPending: false, canRequire: true, problem: nil) == nil)
        #expect(OwnerKeyText.requireNote(required: true, offPending: true, canRequire: true, problem: nil)
                == "Approve on Telegram to turn this off.")
        #expect(OwnerKeyText.requireNote(required: true, offPending: false, canRequire: true, problem: "offline") == "offline")
        let key = OwnerKeyRow(id: "k", label: "studio\u{202E}mac", status: "approved", created: "",
                              approvedAt: "2026-10-28T08:01:00+00:00")
        #expect(OwnerKeyText.row(key, locale: Locale(identifier: "en_GB"), timeZone: TimeZone(identifier: "UTC")!)
                == "studio⟨U+202E⟩mac · approved 28 Oct")
        let waiting = OwnerKeyRow(id: "k", label: "mini", status: "pending", created: "")
        #expect(OwnerKeyText.row(waiting) == "mini · waiting")
    }
}

/// A Touch ID prompt that stays up until the test answers it.
@MainActor final class PresenceGate {
    private var continuation: CheckedContinuation<Bool, Never>?
    private(set) var asked = 0
    var waiting: Bool { continuation != nil }

    func wait() async -> Bool {
        asked += 1
        return await withCheckedContinuation { continuation = $0 }
    }

    func open(_ answer: Bool) {
        continuation?.resume(returning: answer)
        continuation = nil
    }
}
