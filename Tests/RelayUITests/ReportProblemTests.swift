import Foundation
import RelayCore
import Testing
@testable import RelayUI

/// Report a Problem (Task 3.9, and its UI in 0.12): the note's rules, the owner key, the
/// Pond's refusals, the composer's state and the reported icon.
@Suite @MainActor struct ReportProblemTests {
    private func started(_ defaults: TestDefaults, bodies: [Instructable] = [idSteps(3)], approved: Bool = true,
                         identity: SourceIdentity = mailboxIdentity) async -> (Store, FakeQueueSource, AskDetail) {
        let store = reviewingStore(defaults)
        store.ownerKeyApproved = { _, _ in approved }
        let ask = revised("a", bodies)
        let fake = FakeQueueSource(items: [ask.item], details: ["a": ask.detail])
        await start(store, fake, identity: identity)
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
        #expect(!ProblemReport.showsCounter(String(repeating: "x", count: 249)))
        #expect(ProblemReport.showsCounter(String(repeating: "x", count: 250)))
        #expect(ProblemReport.composerTitle(label: "2") == "Problem with step 2")
        #expect(ProblemReport.composerTitle(label: "3b") == "Problem with step 3b")
        #expect(ProblemReport.composerTitle(label: "Verify") == "Problem with Verify")
    }

    @Test func aReportedStepShowsOnlyAnIconWithHelpAndALabel() {
        #expect(ProblemReport.reportedHelp == "Reported. Waiting for a correction.")
        #expect(ProblemReport.reportedLabel == "Problem reported, waiting for a correction")
    }

    @Test func beginAndEndAReport() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let (store, _, _) = await started(defaults)
        store.beginReport("a", path: "2")
        #expect(store.reporting == ["a": "2"])
        #expect(store.navigation.selectedID == "a")
        #expect(store.detail("a")?.reportTarget == "2")
        #expect(store.detail("a")?.canReport == true)
        store.endReport("a")
        #expect(store.reporting.isEmpty)
        #expect(store.detail("a")?.reportTarget == nil)
    }

    @Test func theRowMenuTargetsTheFirstUntickedActionableStep() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let (store, _, _) = await started(defaults)
        store.toggleTick("1", in: "a")
        store.beginReport("a")
        #expect(store.reporting["a"] == "2")
        #expect(store.navigation.selectedID == "a")
    }

    @Test func aRequiredQuestionIsNotATarget() {
        let question = Question(prompt: "Which one?")
        let nodes = DetailModel.nodes(steps: [Step(action: "Pick", question: question, id: "s1"),
                                              Step(action: "Run", code: "run", id: "s2")], verify: nil)
        #expect(!ProblemReport.actionable(nodes[0]))
        #expect(ProblemReport.firstTarget(nodes: nodes, ticks: []) == "2")
        #expect(ProblemReport.firstTarget(nodes: DetailModel.nodes(steps: [Step(action: "No id")], verify: nil),
                                          ticks: []) == nil)
    }

    @Test func theComposerSendsAndCloses() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let (store, fake, _) = await started(defaults)
        store.beginReport("a", path: "2")
        #expect(await store.sendReport("a", note: "the flag is wrong") == .sent)
        #expect(await fake.problems.first?.stepID == "s2")
        #expect(store.reporting["a"] == nil)
        #expect(store.detail("a")?.reported == ["2"])
    }

    @Test func aRefusalStaysInTheComposer() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let (store, fake, _) = await started(defaults)
        store.beginReport("a", path: "2")
        await fake.failNext(QueueError.rejected(status: 400, error: "invalid problem", details: ["note: secret-like value"]),
                            on: "problem")
        _ = await store.sendReport("a", note: "token abc")
        #expect(store.reporting["a"] == "2")
        #expect(store.detail("a")?.report == .failed(ProblemReport.secretRefused))
    }

    @Test func aHeldNoteSendsOnceTheKeyIsApproved() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let (store, fake, _) = await started(defaults, approved: false)
        var setUps = 0
        store.shell.setUpOwnerKey = { setUps += 1 }
        store.beginReport("a", path: "2")
        #expect(store.detail("a")?.ownerKeyReady == false)
        #expect(await store.sendReport("a", note: "the flag is wrong") == .notEnrolled)
        #expect(setUps == 1)
        #expect(store.detail("a")?.report == .held)
        #expect(await fake.count("problem") == 0)

        await store.flushHeldReports()          // still not approved: still held
        #expect(await fake.count("problem") == 0)
        #expect(store.detail("a")?.report == .held)

        store.ownerKeyApproved = { _, _ in true }
        await store.flushHeldReports()
        #expect(await fake.problems.first?.note == "the flag is wrong")
        #expect(await fake.problems.first?.stepID == "s2")
        #expect(store.reporting["a"] == nil)
    }

    @Test func aHeldNoteIsDroppedWhenTheAskCloses() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let (store, fake, detail) = await started(defaults, approved: false)
        store.beginReport("a", path: "2")
        _ = await store.sendReport("a", note: "the flag is wrong")
        var shut = detail
        shut.item = closed(detail.item)
        await fake.setItems([])
        await fake.setClosed([shut.item])
        await fake.setDetail(shut)
        await store.refresh()
        store.ownerKeyApproved = { _, _ in true }
        await store.flushHeldReports()
        #expect(await fake.count("problem") == 0)
        #expect(store.reporting["a"] == nil)
    }

    @Test func reportIsHiddenOnThisMac() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let (store, _, _) = await started(defaults, identity: localIdentity)
        #expect(store.detail("a")?.canReport == false)
        #expect(store.talk == .none)
        store.beginReport("a", path: "2")
        #expect(store.reporting.isEmpty)
    }

    @Test func reportIsHiddenOnAClosedAsk() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let store = reviewingStore(defaults)
        store.ownerKeyApproved = { _, _ in true }
        let ask = revised("a", [idSteps(3)])
        var shut = ask.detail
        shut.item = closed(ask.item)
        let fake = FakeQueueSource(items: [], details: ["a": shut])
        await fake.setClosed([shut.item])
        await start(store, fake, identity: mailboxIdentity)
        store.open("a")
        _ = await eventually { store.detail("a")?.model != nil }
        #expect(store.detail("a")?.canReport == false)
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

    @Test func theIconShowsAfterASendAndGoesOnceTheStepIsCorrected() async throws {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let (store, fake, _) = await started(defaults, bodies: [idSteps(3)])
        #expect(await store.reportProblem("a", stepID: "s2", note: "the flag is wrong") == .sent)
        #expect(store.detail("a")?.reported == ["2"])

        // Rev 2 changes s2; once accepted, the icon goes. A rev that leaves s2 alone keeps it.
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
