import Foundation
import RelayCore
import Testing
@testable import RelayUI

/// Report a Problem (Task 3.9, and its UI in 0.12): the note's rules, the owner key, the
/// Pond's refusals, the composer's state and the reported icon.
private let pond140 = PondVersion.semver(SemVer(major: 1, minor: 4, patch: 0))
private let pond130 = PondVersion.semver(SemVer(major: 1, minor: 3, patch: 0))

/// A pasted traceback: 14 lines, 937 characters (the spec's case).
let traceback: String = {
    var lines = ["Traceback (most recent call last):"]
    for n in 1...12 { lines.append("  File \"/Users/me/deploy/step_\(n).py\", line \(n * 7), in rotate") }
    let head = lines.joined(separator: "\n") + "\n"
    let tail = "KeyError: "
    let pad = 937 - head.unicodeScalars.count - tail.unicodeScalars.count
    return head + tail + String(repeating: "k", count: max(0, pad))
}()

@Suite @MainActor struct ReportProblemTests {
    private func started(_ defaults: TestDefaults, bodies: [Instructable] = [idSteps(3)], approved: Bool = true,
                         identity: SourceIdentity = mailboxIdentity) async -> (Store, FakeQueueSource, AskDetail) {
        let store = await reviewingStore(defaults)
        store.ownerKeyApproved = { _, _ in approved }
        let ask = revised("a", bodies)
        let fake = FakeQueueSource(items: [ask.item], details: ["a": ask.detail])
        await start(store, fake, identity: identity)
        return (store, fake, ask.detail)
    }

    @Test func theNoteRules() {
        #expect(!ProblemReport.canSend(String(repeating: "x", count: 301), limits: .old))
        #expect(ProblemReport.canSend(String(repeating: "x", count: 300), limits: .old))
        #expect(!ProblemReport.canSend("   \n ", limits: .old))
        #expect(!ProblemReport.canSend("   \n ", limits: TalkLimits.make(pond: pond140)))
        #expect(ProblemReport.clean("wrong\nflag\r\nhere ") == "wrong flag  here")
        #expect(ProblemReport.help == "The session gets this as a quoted report about its step. "
            + "Don't paste secrets; the Pond refuses them.")
        #expect(ProblemReport.menuTitle == "Report a Problem…")
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

    @Test func reportOnAnotherStepKeepsEachStepsDraft() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let (store, _, _) = await started(defaults)
        store.beginReport("a", path: "2")
        store.reportDrafts["a"] = "step two's flag is wrong"
        store.beginReport("a", path: "3")
        #expect(store.reporting["a"] == "3")
        #expect(store.reportDrafts["a"] == nil)
        store.reportDrafts["a"] = "step three times out"
        store.beginReport("a", path: "2")
        #expect(store.reportDrafts["a"] == "step two's flag is wrong")
        store.beginReport("a", path: "3")
        #expect(store.reportDrafts["a"] == "step three times out")
        // Cancel drops the open step's text only.
        store.endReport("a")
        store.beginReport("a", path: "3")
        #expect(store.reportDrafts["a"] == nil)
        store.beginReport("a", path: "2")
        #expect(store.reportDrafts["a"] == "step two's flag is wrong")
    }

    @Test func aHeldNoteMovedOffItsStepComesBackAsItsDraft() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let (store, fake, _) = await started(defaults, approved: false)
        store.shell.setUpOwnerKey = {}
        store.beginReport("a", path: "2")
        #expect(await store.sendReport("a", note: "the flag is wrong") == .notEnrolled)
        store.beginReport("a", path: "3")
        #expect(store.detail("a")?.report != .held)
        store.ownerKeyApproved = { _, _ in true }
        await store.flushHeldReports()
        #expect(await fake.count("problem") == 0)
        store.beginReport("a", path: "2")
        #expect(store.reportDrafts["a"] == "the flag is wrong")
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

    /// 0.14: the report opens inline in its step; nothing docks above the action bar.
    @Test func noDockedComposer() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let (store, _, _) = await started(defaults)
        store.beginReport("a", path: "2")
        let snapshot = store.detail("a")!
        #expect(snapshot.reportTarget == "2")
        #expect(DetailView<Store>.barKinds(snapshot, reviewing: false) == [.action])
    }

    /// Each row's slot carries what its inline field needs.
    @Test func slotCarriesStateAndLimits() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let (store, _, _) = await started(defaults)
        store.setPond(pond140)
        store.beginReport("a", path: "2")
        store.reportDrafts["a"] = "the flag is wrong"
        let reports = DetailSteps<Store>.reports(store.detail("a")!, model: store)
        let slot = reports.slot("2")
        #expect(slot.targeted)
        #expect(slot.state == .idle)
        #expect(slot.keyReady)
        #expect(slot.limits == .long)
        #expect(slot.draft == "the flag is wrong")
        #expect(!reports.slot("1").targeted)
        slot.onEdit("the flag is wrong in step 2")
        #expect(store.reportDrafts["a"] == "the flag is wrong in step 2")
        slot.onCancel()
        #expect(store.reporting["a"] == nil)
    }

    @Test func sendClosesFieldAndMarksReported() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let (store, fake, _) = await started(defaults)
        store.beginReport("a", path: "2")
        store.reportDrafts["a"] = "the flag is wrong"
        #expect(await store.sendReport("a", note: "the flag is wrong") == .sent)
        #expect(await fake.problems.first?.note == "the flag is wrong")
        #expect(store.reporting["a"] == nil)
        #expect(store.reportDrafts["a"] == nil)
        #expect(store.detail("a")?.reported == ["2"])
        // A reported step offers no Report link, only the icon.
        let slot = DetailSteps<Store>.reports(store.detail("a")!, model: store).slot("2")
        #expect(slot.reported)
        #expect(!StepRow.showsReportLink(slot, open: true, locked: false))
    }

    @Test func cancelKeepsNothing() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let (store, _, _) = await started(defaults, approved: false)
        store.beginReport("a", path: "2")
        store.reportDrafts["a"] = "half a note"
        _ = await store.sendReport("a", note: "half a note")
        #expect(store.detail("a")?.report == .held)
        store.reportFocus = "a"
        store.endReport("a")
        #expect(store.reporting["a"] == nil)
        #expect(store.reportDrafts["a"] == nil)
        #expect(store.reportFocus == nil)
        #expect(store.detail("a")?.report == .idle)
        store.beginReport("a", path: "2")
        #expect(store.reportDrafts["a"] == nil)
        #expect(store.detail("a")?.report == .idle)
    }

    /// Without an approved key the button stays Send; the held caption shows under the field.
    @Test func heldShowsCaptionNotSetUpButton() {
        #expect(InlineReportField.caption(.held) == ProblemReport.heldCaption)
        #expect(InlineReportField.caption(.failed("The Pond refused the note: it looks like a secret."))
            == "The Pond refused the note: it looks like a secret.")
        #expect(InlineReportField.caption(.idle) == nil)
        #expect(InlineReportField.sendTitle == "Send")
        #expect(ProblemReport.linkTitle == "Report")
        #expect(ProblemReport.placeholder == "What went wrong? Paste the error if there is one.")
        #expect(!InlineReportField.canSend("the flag", limits: .old, state: .held))
        #expect(!InlineReportField.canSend("the flag", limits: .old, state: .sending))
        #expect(InlineReportField.canSend("the flag", limits: .old, state: .idle))
        #expect(!InlineReportField.canSend(String(repeating: "x", count: 301), limits: .old, state: .idle))
        #expect(InlineReportField.canSend(String(repeating: "x", count: 301), limits: .long, state: .idle))
    }

    /// ⌘Return in the report field sends the report (never Done), through the key router.
    @Test func commandReturnSendsTheReport() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let (store, fake, _) = await started(defaults)
        store.beginReport("a", path: "2")
        store.reportDrafts["a"] = "the flag is wrong"
        store.reportFocus = "a"
        let context = store.keyContext(textFieldFocused: true, popoverOpen: false, closedHeaderFocused: false)
        #expect(context.reportFieldFocused)
        #expect(KeyMap.command(for: .cmdReturn, in: context) == .sendReport)
        store.perform(.sendReport)
        _ = await eventually { await fake.count("problem") == 1 }
        #expect(await fake.problems.first?.note == "the flag is wrong")
        #expect(await fake.count("resolve") == 0)
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
        let store = await reviewingStore(defaults)
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

    /// Pond 1.4.0: a long, multi-line note reaches the Pond as typed, its ends trimmed.
    @Test func multilineNoteOn140() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        #expect(traceback.unicodeScalars.count == 937)
        #expect(traceback.split(separator: "\n").count == 14)
        let (store, fake, _) = await started(defaults)
        store.setPond(pond140)
        #expect(store.detail("a")?.limits == TalkLimits.make(pond: pond140))
        #expect(await store.reportProblem("a", stepID: "s2", note: "\n" + traceback + "\n") == .sent)
        #expect(await fake.problems.first?.note == traceback)
        let long = String(repeating: "x", count: 8000)
        #expect(await store.reportProblem("a", stepID: "s2", note: long) == .sent)
        if case .refused = await store.reportProblem("a", stepID: "s2", note: long + "x") {} else {
            Issue.record("8001 characters should be refused")
        }
        #expect(await fake.count("problem") == 2)
    }

    /// Pond 1.3.0: the 0.12 rules stay, one line and 300 characters, and nothing is cut to fit.
    @Test func oldPondReportStaysOneLine() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let (store, fake, _) = await started(defaults)
        store.setPond(pond130)
        #expect(store.detail("a")?.limits == .old)
        #expect(await store.reportProblem("a", stepID: "s2", note: "the flag\nis wrong\n") == .sent)
        #expect(await fake.problems.first?.note == "the flag is wrong")
        if case .refused = await store.reportProblem("a", stepID: "s2", note: String(repeating: "x", count: 301)) {} else {
            Issue.record("301 characters should be refused")
        }
        if case .refused = await store.reportProblem("a", stepID: "s2", note: traceback) {} else {
            Issue.record("the traceback should be refused on 1.3.0")
        }
        #expect(await fake.count("problem") == 1)
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
