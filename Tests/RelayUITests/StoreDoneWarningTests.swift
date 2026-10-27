import Foundation
import RelayCore
import Testing
@testable import RelayUI

private let ask = Question(prompt: "Which environment?", choices: ["Staging", "Prod"])

/// "q": 1 asks a question, 2 plain; a free-text reply.
private func questionItem() -> WireItem {
    let ins = Instructable(v: 1, title: "Ask q", urgency: "today", steps: [
        Step(action: "Pick the target", question: ask),
        Step(action: "Run the deploy"),
    ], reply: ReplySpec(prompt: "Anything else?"))
    let created = stamp(minutesAgo: 5)
    return WireItem(id: "q", title: "Ask q", status: "open", projectId: "Acme", created: created, updated: created,
                    payload: Payload(why: nil, cmd: nil, link: nil, instructable: ins))
}

@MainActor private func context(_ store: Store) -> KeyContext {
    store.keyContext(textFieldFocused: false, popoverOpen: false, closedHeaderFocused: false)
}

/// Done with something unsent never sends or drops it silently: the bar warns first.
@Suite @MainActor struct StoreDoneWarningTests {
    private func setUp() async -> (Store, FakeQueueSource, TestDefaults) {
        let defaults = TestDefaults()
        let store = Store(defaults: defaults.defaults)
        let fake = FakeQueueSource(items: [questionItem(), item("b", created: stamp(minutesAgo: 9))])
        await start(store, fake)
        store.open("q")
        return (store, fake, defaults)
    }

    @Test func doneWithNothingUnsentCloses() async {
        let (store, _, defaults) = await setUp()
        defer { defaults.drop() }
        store.warnUnsent("q")
        #expect(store.pending.contains("q"))
        #expect(store.doneWarnings.isEmpty)
    }

    @Test func doneWithAnUnsentReplyWarnsAndSendsNothing() async {
        let (store, fake, defaults) = await setUp()
        defer { defaults.drop() }
        store.drafts["q"] = "All set"
        #expect(KeyMap.command(for: .cmdReturn, in: context(store)) == .warnUnsent)
        store.perform(.warnUnsent)
        #expect(store.pending.isEmpty)
        #expect(await fake.count("reply") == 0)
        let snapshot = store.detail("q")
        #expect(snapshot?.doneWarning == true)
        #expect(snapshot?.unsentKind == .reply)
        #expect(context(store).doneWarning)
        #expect(KeyMap.command(for: .cmdReturn, in: context(store)) == .sendAndDone)
    }

    @Test func anUnsentAnswerIsNamedOverTheReply() async {
        let (store, _, defaults) = await setUp()
        defer { defaults.drop() }
        store.answerDrafts["q"] = ["1": .picked(["Prod"])]
        store.drafts["q"] = "All set"
        store.warnUnsent("q")
        #expect(store.detail("q")?.unsentKind == .answer)
        #expect(store.detail("q").map(DetailView<Store>.answers)?.caption == "You have an unsent answer")
    }

    @Test func escGoesBackToEditingWithEverythingKept() async {
        let (store, _, defaults) = await setUp()
        defer { defaults.drop() }
        store.drafts["q"] = "All set"
        store.warnUnsent("q")
        #expect(KeyMap.command(for: .escape, in: context(store)) == .cancelDoneWarning)
        store.perform(.cancelDoneWarning)
        #expect(store.doneWarnings.isEmpty)
        #expect(store.navigation.selectedID == "q")
        #expect(store.drafts["q"] == "All set")
        #expect(store.pending.isEmpty)
    }

    @Test func sendAndDoneSendsThenCloses() async {
        let (store, fake, defaults) = await setUp()
        defer { defaults.drop() }
        store.answerDrafts["q"] = ["1": .picked(["Prod"])]
        store.drafts["q"] = "All set"
        store.warnUnsent("q")
        await store.sendAndDone("q")
        let calls = await fake.calls.filter { $0.hasPrefix("answer") || $0.hasPrefix("reply") }
        #expect(calls == ["answer q", "reply q"])
        #expect(store.pending.contains("q"))
        #expect(store.doneWarnings.isEmpty)
    }

    @Test func aFailedSendKeepsTheWarningUp() async {
        let (store, fake, defaults) = await setUp()
        defer { defaults.drop() }
        await fake.failNext(QueueError.unreachable("timed out"), on: "reply")
        store.drafts["q"] = "All set"
        store.warnUnsent("q")
        await store.sendAndDone("q")
        #expect(store.pending.isEmpty)
        #expect(store.detail("q")?.doneWarning == true)
        #expect(store.drafts["q"] == "All set")
    }

    @Test func discardAndDoneDropsTheUnsentAndClosesWithoutSending() async {
        let (store, fake, defaults) = await setUp()
        defer { defaults.drop() }
        store.answerDrafts["q"] = ["1": .picked(["Prod"])]
        store.drafts["q"] = "All set"
        store.warnUnsent("q")
        store.perform(.discardAndDone)
        #expect(store.pending.contains("q"))
        #expect(store.drafts["q"] == nil)
        #expect(store.answerDrafts["q"] == nil)
        #expect(store.doneWarnings.isEmpty)
        #expect(await fake.count("reply") == 0)
        #expect(await fake.count("answer") == 0)
    }

    /// Sending the reply from its own box clears the warning; typing again doesn't bring it back.
    @Test func theWarningGoesOnceNothingIsUnsent() async {
        let (store, _, defaults) = await setUp()
        defer { defaults.drop() }
        store.drafts["q"] = "All set"
        store.warnUnsent("q")
        #expect(await store.sendReply("q"))
        #expect(store.doneWarnings.isEmpty)
        store.drafts["q"] = "One more thing"
        #expect(store.detail("q")?.doneWarning == false)
    }

    @Test func leavingTheAskEndsTheWarning() async {
        let (store, _, defaults) = await setUp()
        defer { defaults.drop() }
        store.drafts["q"] = "All set"
        store.warnUnsent("q")
        store.back()
        #expect(store.doneWarnings.isEmpty)
        store.open("q")
        #expect(store.detail("q")?.doneWarning == false)
        #expect(store.drafts["q"] == "All set")
    }
}
