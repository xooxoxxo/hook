import Foundation
import RelayCore
import Testing
@testable import RelayUI

/// The whole-ask lock (Task 3.6): every copy and open path refuses while a correction is
/// unreviewed, Done is bound to the revision shown, and only Skip still goes through.
@Suite @MainActor struct ReviewGuardTests {
    private func pendingStore(_ defaults: TestDefaults, recorder: ShellRecorder, urls: [Int: String] = [:])
        async -> (Store, FakeQueueSource, AskDetail) {
        let store = await reviewingStore(defaults)
        store.shell = recorder.shell
        let two = revised("a", [idSteps(3, urls: urls), idSteps(4, urls: urls)])
        let fake = FakeQueueSource(items: [two.item], details: ["a": two.detail])
        await start(store, fake)
        store.open("a")
        return (store, fake, two.detail)
    }

    @Test func copyWithTheShownStampWhilePendingIsRefused() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let recorder = ShellRecorder()
        let (store, _, detail) = await pendingStore(defaults, recorder: recorder)
        let snapshot = store.detail("a")
        #expect(snapshot?.locked == true)
        #expect(snapshot?.stamp == detail.revisions[0].stamp)
        #expect(store.copyCode("a", stamp: snapshot?.stamp, text: "run 1") == .refused)
        #expect(store.copyCode("a", stamp: detail.revisions[1].stamp, text: "run 1") == .refused)
        #expect(recorder.copied.isEmpty)
    }

    @Test func aCorrectionBetweenRenderAndClickRefusesTheCopy() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let recorder = ShellRecorder()
        let (store, fake, detail) = await pendingStore(defaults, recorder: recorder)
        markAccepted(store, "a", detail.revisions[1].stamp)
        let rendered = store.detail("a")
        #expect(rendered?.locked == false)
        #expect(rendered?.stamp == detail.revisions[1].stamp)
        #expect(store.copyCode("a", stamp: rendered?.stamp, text: "run 4") == .copied)
        // Rev 3 arrives with the next poll, before the next click.
        let three = revised("a", [idSteps(3), idSteps(4), idSteps(5)])
        await fake.setItems([three.item])
        await fake.setDetail(three.detail)
        await store.refresh()
        #expect(store.copyCode("a", stamp: rendered?.stamp, text: "run 4") == .refused)
        #expect(recorder.copied == ["run 4"])
    }

    @Test func aTextTheRevisionDoesNotShowIsRefused() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let recorder = ShellRecorder()
        let store = await reviewingStore(defaults)
        store.shell = recorder.shell
        let one = revised("a", [idSteps(2)])
        await start(store, FakeQueueSource(items: [one.item], details: ["a": one.detail]))
        let stamp = store.detail("a")?.stamp
        #expect(store.copyCode("a", stamp: stamp, text: "something else") == .refused)
        #expect(store.copyCode("a", stamp: stamp, text: "run 2") == .copied)
        #expect(recorder.copied == ["run 2"])
    }

    @Test func theCopyAndOpenShortcutsAreRefusedWhilePending() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let recorder = ShellRecorder()
        let (store, _, _) = await pendingStore(defaults, recorder: recorder, urls: [1: "https://example.com/a"])
        store.perform(.copyCurrentCode)
        store.perform(.openCurrentURL)
        store.openStepURL("a", stamp: store.detail("a")?.stamp, url: URL(string: "https://example.com/a")!)
        #expect(recorder.copied.isEmpty)
        #expect(recorder.opened.isEmpty)
    }

    @Test func theShortcutsWorkOnceAccepted() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let recorder = ShellRecorder()
        let (store, _, detail) = await pendingStore(defaults, recorder: recorder, urls: [1: "https://example.com/a"])
        markAccepted(store, "a", detail.revisions[1].stamp)
        store.perform(.copyCurrentCode)
        store.perform(.openCurrentURL)
        #expect(recorder.copied == ["run 1"])
        #expect(recorder.opened == [URL(string: "https://example.com/a")!])
        // A URL no step names is never opened.
        store.openStepURL("a", stamp: detail.revisions[1].stamp, url: URL(string: "https://evil.example")!)
        #expect(recorder.opened.count == 1)
    }

    /// Every link the detail shows (a step's link, a link, Markdown in a step's detail) opens and
    /// copies through the Store's stamp-bound check, never straight to the shell.
    @Test func everyLinkPathGoesThroughTheStampBoundCheck() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let recorder = ShellRecorder()
        var body = idSteps(2, urls: [1: "https://example.com/a"])
        body.steps[1].detail = "See [the docs](https://example.com/docs)."
        var corrected = body
        corrected.steps[0].code = "run one"
        let store = await reviewingStore(defaults)
        store.shell = recorder.shell
        let two = revised("a", [body, corrected])
        let fake = FakeQueueSource(items: [two.item], details: ["a": two.detail])
        await start(store, fake)
        store.open("a")
        let step = URL(string: "https://example.com/a")!, docs = URL(string: "https://example.com/docs")!

        // Locked: nothing opens or copies, whatever the stamp.
        for stamp in [store.detail("a")?.stamp, two.detail.revisions[1].stamp] {
            store.openStepURL("a", stamp: stamp, url: step)
            store.openStepURL("a", stamp: stamp, url: docs)
            #expect(store.copyLinkAddress("a", stamp: stamp, url: step) == .refused)
            #expect(store.copyLinkAddress("a", stamp: stamp, url: docs) == .refused)
        }
        #expect(recorder.opened.isEmpty)
        #expect(recorder.copied.isEmpty)

        markAccepted(store, "a", two.detail.revisions[1].stamp)
        let shown = store.detail("a")?.stamp
        store.openStepURL("a", stamp: shown, url: docs)
        #expect(store.copyLinkAddress("a", stamp: shown, url: step) == .copied)
        #expect(store.copyLinkAddress("a", stamp: shown, url: URL(string: "https://evil.example")!) == .refused)
        #expect(recorder.opened == [docs])
        #expect(recorder.copied == ["https://example.com/a"])

        // A correction lands between the render and the click: the old stamp opens nothing.
        let three = revised("a", [body, corrected, idSteps(3)])
        await fake.setItems([three.item])
        await fake.setDetail(three.detail)
        await store.refresh()
        store.openStepURL("a", stamp: shown, url: docs)
        #expect(store.copyLinkAddress("a", stamp: shown, url: step) == .refused)
        #expect(recorder.opened == [docs])
        #expect(recorder.copied == ["https://example.com/a"])
    }

    @Test func doneAnswersRepliesAndTicksAreRefusedWhilePendingAndSkipIsNot() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let recorder = ShellRecorder()
        var asking = idSteps(2)
        asking.steps[1].question = Question(prompt: "Env?", choices: ["A", "B"])
        asking.reply = ReplySpec(prompt: "Anything?")
        var corrected = asking
        corrected.steps[0].code = "run one"
        let store = await reviewingStore(defaults)
        store.shell = recorder.shell
        let two = revised("a", [asking, corrected])
        let fake = FakeQueueSource(items: [two.item], details: ["a": two.detail])
        await start(store, fake)
        store.open("a")

        store.close("a", .done)
        #expect(!store.pending.contains("a"))
        store.answerDrafts["a"] = ["2": .picked(["A"])]
        #expect(!(await store.sendAnswers("a")))
        store.drafts["a"] = "hello"
        #expect(!(await store.sendReply("a")))
        store.toggleTick("1", in: "a")
        #expect(store.ticks(for: "a").isEmpty)
        #expect(store.tickCurrent(in: "a") == nil)
        await store.sendAndDone("a")
        #expect(!store.pending.contains("a"))
        #expect(await fake.count("answer") == 0)
        #expect(await fake.count("reply") == 0)

        store.close("a", .declined)
        #expect(store.pending.contains("a"))
        #expect(store.pending.entry("a")?.stamp == nil)
    }

    @Test func doneIsBoundToTheShownRevision() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let clock = TestClock()
        let store = await reviewingStore(defaults, now: { clock.now })
        let two = revised("a", [idSteps(3), idSteps(4)])
        let fake = FakeQueueSource(items: [two.item], details: ["a": two.detail])
        await start(store, fake)
        markAccepted(store, "a", two.detail.revisions[1].stamp)
        store.close("a", .done)
        #expect(store.pending.entry("a")?.stamp == two.detail.revisions[1].stamp)
        clock.advance(11)
        store.sendDue()
        #expect(await eventually { await fake.count("resolve a done") == 1 })
        let stamps = await fake.stamps
        #expect(stamps.map(\.call) == ["resolve a"])
        #expect(stamps.first?.stamp == two.detail.revisions[1].stamp)
    }

    @Test func aCorrectionWhileDoneIsHeldDropsTheDone() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let clock = TestClock()
        let store = await reviewingStore(defaults, now: { clock.now })
        let two = revised("a", [idSteps(3), idSteps(4)])
        let fake = FakeQueueSource(items: [two.item], details: ["a": two.detail])
        await start(store, fake)
        markAccepted(store, "a", two.detail.revisions[1].stamp)
        store.close("a", .done)
        #expect(store.pending.contains("a"))

        let three = revised("a", [idSteps(3), idSteps(4), idSteps(5)])
        await fake.setItems([three.item])
        await fake.setDetail(three.detail)
        await store.refresh()

        #expect(!store.pending.contains("a"))
        #expect(store.notice == .doneHeldBack(id: "a", title: "Ask a"))
        #expect(store.items.map(\.id) == ["a"])
        clock.advance(11)
        store.sendDue()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await fake.count("resolve") == 0)
    }

    @Test func aStaleDoneThePondRefusesSaysTheAskWasCorrected() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let clock = TestClock()
        let store = await reviewingStore(defaults, now: { clock.now })
        let two = revised("a", [idSteps(3), idSteps(4)])
        let fake = FakeQueueSource(items: [two.item], details: ["a": two.detail])
        await start(store, fake)
        markAccepted(store, "a", two.detail.revisions[1].stamp)
        store.close("a", .done)
        await fake.failNext(QueueError.corrected(rev: 3, hash: "h", acceptedRev: 2), on: "resolve")
        clock.advance(11)
        store.sendDue()
        #expect(await eventually {
            store.notice == .actionFailed(verdict: .done, id: "a", title: "Ask a", reason: "the ask was corrected")
        })
    }

    @Test func viewInputsReportTheLock() {
        #expect(CodeBlock.allowsSelection(locked: true) == false)
        #expect(CodeBlock.allowsSelection(locked: false) == true)
        #expect(CodeBlock.allowsCopy(locked: true) == false)
        #expect(CodeBlock.allowsCopy(locked: false) == true)
        #expect(FileRowContext(contentLocked: true).actionsEnabled == false)
        #expect(FileRowContext().actionsEnabled == true)
        let content = StepContent(action: "Run", url: "https://example.com", code: "ls")
        #expect(StepRow.actions(content, locked: false, contentLocked: false) == ["Copy command", "Open link"])
        #expect(StepRow.actions(content, locked: false, contentLocked: true).isEmpty)
        #expect(StepRow.actions(content, locked: true, contentLocked: false).isEmpty)
        #expect(OpenLink.menuItems(locked: false) == ["Copy Link Address"])
        #expect(OpenLink.menuItems(locked: true).isEmpty)
        #expect(CopyOutcome.refusedText == "Changed just now. Review first.")
    }
}
