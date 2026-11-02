import Foundation
import RelayCore
import Testing
@testable import RelayUI

/// Report a Problem (Task 3.9): the note's rules, the owner key, the Pond's refusals and the
/// "Reported" caption.
@Suite @MainActor struct ReportProblemTests {
    private func started(_ defaults: TestDefaults, bodies: [Instructable] = [idSteps(3)], approved: Bool = true)
        async -> (Store, FakeQueueSource, AskDetail) {
        let store = reviewingStore(defaults)
        store.ownerKeyApproved = { _, _ in approved }
        let ask = revised("a", bodies)
        let fake = FakeQueueSource(items: [ask.item], details: ["a": ask.detail])
        await start(store, fake)
        return (store, fake, ask.detail)
    }

    @Test func theNoteRules() {
        #expect(!ProblemReport.canSend(String(repeating: "x", count: 301)))
        #expect(ProblemReport.canSend(String(repeating: "x", count: 300)))
        #expect(!ProblemReport.canSend("   \n "))
        #expect(ProblemReport.clean("wrong\nflag\r\nhere ") == "wrong flag  here")
        #expect(ProblemReport.counter("abc") == "3/300")
        #expect(ProblemReport.help == "The session gets this as a quoted report about its step. "
            + "Don't paste secrets; the Pond refuses them.")
        #expect(ProblemReport.menuTitle == "Report a Problem…")
    }

    @Test func aNewlineIsSentAsASpaceOnTheShownRevision() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let (store, fake, detail) = await started(defaults)
        #expect(await store.reportProblem("a", stepID: "s2", note: "the flag\nis wrong") == .sent)
        let sent = await fake.problems
        #expect(sent.count == 1)
        #expect(sent.first?.note == "the flag is wrong")
        #expect(sent.first?.stepID == "s2")
        #expect(sent.first?.stamp == detail.revisions[0].stamp)
    }

    @Test func withoutAnApprovedKeyNothingIsSent() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let (store, fake, _) = await started(defaults, approved: false)
        #expect(await store.reportProblem("a", stepID: "s2", note: "wrong") == .notEnrolled)
        #expect(await fake.count("problem") == 0)
    }

    @Test func aTooLongNoteIsNotSent() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let (store, fake, _) = await started(defaults)
        if case .refused = await store.reportProblem("a", stepID: "s2", note: String(repeating: "x", count: 301)) {} else {
            Issue.record("expected refused")
        }
        #expect(await fake.count("problem") == 0)
    }

    @Test func aSecretLikeNoteIsRefusedInPlainWords() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let (store, fake, _) = await started(defaults)
        await fake.failNext(QueueError.rejected(status: 400, error: "invalid problem", details: ["note: secret-like value"]),
                            on: "problem")
        #expect(await store.reportProblem("a", stepID: "s2", note: "token abc")
            == .refused("The Pond refused the note: it looks like a secret."))
    }

    @Test func reportingWorksWhileLocked() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let (store, fake, detail) = await started(defaults, bodies: [idSteps(3), idSteps(4)])
        #expect(store.reviewState("a").isLocked)
        #expect(await store.reportProblem("a", stepID: "s1", note: "wrong") == .sent)
        #expect(await fake.problems.first?.stamp == detail.revisions[0].stamp)
    }

    @Test func theCaptionShowsAfterASendAndGoesOnceTheStepIsCorrected() async throws {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let (store, fake, _) = await started(defaults, bodies: [idSteps(3)])
        #expect(await store.reportProblem("a", stepID: "s2", note: "the flag is wrong") == .sent)
        #expect(store.detail("a")?.reported == ["2"])

        // Rev 2 changes s2; once accepted, the caption goes. A rev that leaves s2 alone keeps it.
        var events = (try await fake.get("a")).events
        let two = revised("a", [idSteps(3), idSteps(3, codes: [2: "run 2 --fixed"])], events: events)
        await fake.setItems([two.item])
        await fake.setDetail(two.detail)
        await store.refresh()
        markAccepted(store, "a", two.detail.revisions[1].stamp)
        #expect(store.detail("a")?.reported == [])

        events = (try await fake.get("a")).events
        let other = revised("a", [idSteps(3), idSteps(3, codes: [3: "run 3 --other"])], events: events)
        await fake.setItems([other.item])
        await fake.setDetail(other.detail)
        await store.refresh()
        markAccepted(store, "a", other.detail.revisions[1].stamp)
        #expect(store.detail("a")?.reported == ["2"])
    }
}
