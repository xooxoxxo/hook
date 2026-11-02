import Foundation
import RelayCore
import Testing
@testable import RelayUI

/// Use Version N (Task 3.8): Touch ID for a changed command, link or file, the sealed local
/// acceptance, the Pond call and its retries.
@Suite @MainActor struct AcceptTests {
    private struct Setup {
        let store: Store
        let fake: FakeQueueSource
        let recorder: ShellRecorder
        let detail: AskDetail
        let url: URL
        let secrets: MemorySecretStore
        var one: RevisionStamp { detail.revisions[0].stamp }
        var two: RevisionStamp { detail.revisions[1].stamp }
    }

    /// Rev 1 has steps s1…s5, shown and accepted here; rev 2 is `corrected`.
    private func setUp(_ defaults: TestDefaults, corrected: Instructable, first: Instructable = idSteps(5),
                       acceptedHere: Bool = true, clock: TestClock? = nil) async -> Setup {
        let secrets = MemorySecretStore(), url = reviewsURL()
        var now: (@MainActor () -> Date)?
        if let clock { now = { clock.now } }
        let store = reviewingStore(defaults, secrets: secrets, url: url, now: now)
        let recorder = ShellRecorder()
        store.shell = recorder.shell
        let ask = revised("a", [first, corrected], acceptedRev: 1)
        let fake = FakeQueueSource(items: [ask.item], details: ["a": ask.detail])
        await start(store, fake)
        if acceptedHere {
            var record = store.record("a") ?? ReviewRecord()
            record.accepted = ask.detail.revisions[0].stamp
            record.seen = ask.detail.revisions[0].stamp
            store.setRecord(record, for: "a")
            store.rerender("a")
        }
        return Setup(store: store, fake: fake, recorder: recorder, detail: ask.detail, url: url, secrets: secrets)
    }

    @Test func aCodeChangeWithoutPresenceAcceptsNothing() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let s = await setUp(defaults, corrected: idSteps(5, codes: [3: "run three --force"]))
        defer { try? FileManager.default.removeItem(at: s.url) }
        s.recorder.presence = false
        #expect(!(await s.store.acceptRevision("a", stamp: s.two)))
        #expect(s.recorder.presenceAsked == ["accept a changed command, link or file in “Ask a”"])
        #expect(s.store.record("a")?.accepted == s.one)
        #expect(await s.fake.count("accept") == 0)
        #expect(s.store.reviewState("a").isLocked)
    }

    @Test func withPresenceTheAcceptanceIsSealedAndSentOnce() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let s = await setUp(defaults, corrected: idSteps(5, codes: [3: "run three --force"]))
        defer { try? FileManager.default.removeItem(at: s.url) }
        #expect(await s.store.acceptRevision("a", stamp: s.two))
        #expect(s.recorder.presenceAsked.count == 1)
        #expect(await s.fake.count("accept a @2") == 1)
        #expect(s.store.record("a")?.accepted == s.two)
        #expect(s.store.record("a")?.pondAcceptPending == false)
        #expect(s.store.reviewState("a") == .current(s.two))
        #expect(s.store.listed.first?.instructable?.steps[2].code == "run three --force")
        let saved = ReviewStore.load(from: s.url, sealKey: try! ReviewSeal.loadOrCreate(s.secrets))
        #expect(!saved.tampered)
        #expect(saved.records[ReviewStore.key(sourceKey: localIdentity.key, id: "a")]?.accepted == s.two)
    }

    @Test func anExpectOnlyChangeNeedsNoPresence() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        var changed = idSteps(5)
        changed.steps[1].expect = "Build succeeded"
        let s = await setUp(defaults, corrected: changed)
        defer { try? FileManager.default.removeItem(at: s.url) }
        #expect(await s.store.acceptRevision("a", stamp: s.two))
        #expect(s.recorder.presenceAsked.isEmpty)
    }

    @Test func aStaleStampIsRefusedWithoutAPrompt() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let s = await setUp(defaults, corrected: idSteps(5, codes: [3: "run three --force"]))
        defer { try? FileManager.default.removeItem(at: s.url) }
        let three = revised("a", [idSteps(5), idSteps(5, codes: [3: "run three --force"]), idSteps(6)])
        await s.fake.setItems([three.item])
        await s.fake.setDetail(three.detail)
        await s.store.refresh()
        #expect(!(await s.store.acceptRevision("a", stamp: s.two)))
        #expect(s.recorder.presenceAsked.isEmpty)
        #expect(await s.fake.count("accept") == 0)
    }

    @Test func afterAcceptChangedAndAddedStepsShowChipsAndLoseTicks() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        var corrected = idSteps(5, codes: [3: "run three --force"])
        corrected.steps.append(Step(action: "Step 6", code: "run 6", id: "s6"))
        let s = await setUp(defaults, corrected: corrected)
        defer { try? FileManager.default.removeItem(at: s.url) }
        // Ticked at rev 1, before the correction arrived (written as the tick store does).
        let rev1 = DetailModel.make(item: revised("a", [idSteps(5)]).item, events: []).nodes
        TickStore.save(defaults.defaults, sourceKey: localIdentity.key, id: "a", ticks: ["2", "3"], nodes: rev1)
        s.store.answerDrafts["a"] = ["3": .text("old draft")]
        #expect(await s.store.acceptRevision("a", stamp: s.two))

        let snapshot = s.store.detail("a")
        #expect(snapshot?.changedSteps == ["3": .changed, "6": .new])
        #expect(snapshot?.ticks == ["2"])
        #expect(s.store.answerDrafts["a"] == nil)
        #expect(s.store.detailAnchor["a"] == "3")
        s.store.toggleTick("3", in: "a")
        #expect(s.store.detail("a")?.changedSteps == ["6": .new])
        #expect(s.store.record("a")?.changed == ["s6"])
    }

    @Test func aFailedPondAcceptIsSentAgainBeforeDone() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let clock = TestClock()
        let s = await setUp(defaults, corrected: idSteps(5, codes: [3: "run three --force"]), clock: clock)
        defer { try? FileManager.default.removeItem(at: s.url) }
        await s.fake.failNext(QueueError.unreachable("offline"), on: "accept")
        #expect(await s.store.acceptRevision("a", stamp: s.two))
        #expect(s.store.record("a")?.pondAcceptPending == true)
        #expect(s.store.reviewState("a") == .current(s.two))
        if case .acceptFailed? = s.store.notice {} else { Issue.record("expected acceptFailed, got \(String(describing: s.store.notice))") }

        s.store.close("a", .done)
        clock.advance(11)
        s.store.sendDue()
        #expect(await eventually { await s.fake.count("resolve") == 1 })
        let calls = await s.fake.calls.filter { $0.hasPrefix("accept") || $0.hasPrefix("resolve") }
        #expect(calls == ["accept a @2", "accept a @2", "resolve a done"])
        #expect(s.store.record("a")?.pondAcceptPending == false)
    }

    @Test func aResendThatFailsKeepsTheDoneBackAndSaysWhy() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let clock = TestClock()
        let s = await setUp(defaults, corrected: idSteps(5, codes: [3: "run three --force"]), clock: clock)
        defer { try? FileManager.default.removeItem(at: s.url) }
        await s.fake.failNext(QueueError.unreachable("offline"), on: "accept")
        #expect(await s.store.acceptRevision("a", stamp: s.two))
        await s.fake.failNext(QueueError.rejected(status: 403, error: "owner key required", details: []), on: "accept")
        s.store.close("a", .done)
        clock.advance(11)
        s.store.sendDue()
        #expect(await eventually {
            s.store.notice == .actionFailed(verdict: .done, id: "a", title: "Ask a",
                                            reason: "Set up the owner key in Settings › Queue to act on corrected asks.")
        })
        #expect(await s.fake.count("resolve") == 0)
    }

    @Test func a409BelowTheLocalAcceptanceResendsTheAcceptOnceAndRetries() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let clock = TestClock()
        let s = await setUp(defaults, corrected: idSteps(5, codes: [3: "run three --force"]), clock: clock)
        defer { try? FileManager.default.removeItem(at: s.url) }
        #expect(await s.store.acceptRevision("a", stamp: s.two))
        await s.fake.failNext(QueueError.corrected(rev: 2, hash: s.two.hash, acceptedRev: 1), on: "resolve")
        s.store.close("a", .done)
        clock.advance(11)
        s.store.sendDue()
        #expect(await eventually { await s.fake.count("resolve") == 2 })
        let calls = await s.fake.calls.filter { $0.hasPrefix("accept") || $0.hasPrefix("resolve") }
        #expect(calls == ["accept a @2", "resolve a done", "accept a @2", "resolve a done"])
    }

    @Test func aSecond409IsAFailureNotALoop() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let clock = TestClock()
        let s = await setUp(defaults, corrected: idSteps(5, codes: [3: "run three --force"]), clock: clock)
        defer { try? FileManager.default.removeItem(at: s.url) }
        #expect(await s.store.acceptRevision("a", stamp: s.two))
        await s.fake.failNext(QueueError.corrected(rev: 2, hash: s.two.hash, acceptedRev: 1), on: "resolve")
        await s.fake.failNext(QueueError.corrected(rev: 2, hash: s.two.hash, acceptedRev: 1), on: "resolve")
        s.store.close("a", .done)
        clock.advance(11)
        s.store.sendDue()
        #expect(await eventually {
            s.store.notice == .actionFailed(verdict: .done, id: "a", title: "Ask a", reason: "the ask was corrected")
        })
        #expect(await s.fake.count("accept") == 2)
        #expect(await s.fake.count("resolve") == 2)
    }

    @Test func answersAlsoResendAPendingAcceptFirst() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        var asking = idSteps(5, codes: [3: "run three --force"])
        asking.steps[1].question = Question(prompt: "Env?", choices: ["A", "B"])
        var first = idSteps(5)
        first.steps[1].question = Question(prompt: "Env?", choices: ["A", "B"])
        let s = await setUp(defaults, corrected: asking, first: first)
        defer { try? FileManager.default.removeItem(at: s.url) }
        await s.fake.failNext(QueueError.unreachable("offline"), on: "accept")
        #expect(await s.store.acceptRevision("a", stamp: s.two))
        s.store.answerDrafts["a"] = ["2": .picked(["A"])]
        #expect(await s.store.sendAnswers("a"))
        let calls = await s.fake.calls.filter { $0.hasPrefix("accept") || $0.hasPrefix("answer") }
        #expect(calls == ["accept a @2", "accept a @2", "answer a"])
        #expect(await s.fake.stamps.last?.stamp == s.two)
    }

    @Test func aFirstViewAcceptOfAChangedCommandAsksForPresence() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let s = await setUp(defaults, corrected: idSteps(5, codes: [3: "run three --force"]), acceptedHere: false)
        defer { try? FileManager.default.removeItem(at: s.url) }
        #expect(s.store.reviewState("a") == .pending(shown: nil, current: s.two, baseline: nil))
        #expect(s.store.reviewDiff("a")?.isFirstView == true)
        #expect(await s.store.acceptRevision("a", stamp: s.two))
        #expect(s.recorder.presenceAsked.count == 1)
    }

    @Test func theReviewModelNamesTheChangeAndItsFlags() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let s = await setUp(defaults, corrected: idSteps(5, codes: [3: "sudo run three"]))
        defer { try? FileManager.default.removeItem(at: s.url) }
        let diff = s.store.reviewDiff("a")
        #expect(diff?.steps.map(\.stepID) == ["s3"])
        #expect(diff?.reasons.map(\.reason) == ["Fix step 2"])
        #expect(s.store.lookCloserFlags("a").map(\.kind) == [.sudo])
        #expect(s.store.queue.rows["a"]?.corrected == true)
    }
}
