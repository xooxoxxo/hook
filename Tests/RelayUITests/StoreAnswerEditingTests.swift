import Foundation
import RelayCore
import Testing
@testable import RelayUI

private let sentAt = "2026-10-16T09:30:00+00:00"
private let textAsk = item("t", created: stamp(minutesAgo: 5), reply: ReplySpec(prompt: "Name it"))
private let choiceAsk = item("c", created: stamp(minutesAgo: 6), reply: ReplySpec(prompt: "Where?", choices: ["A", "B"]))

private func reply(_ id: String, _ text: String) -> Event {
    Event(seq: 1, itemId: id, kind: "reply", actor: "owner", text: text, at: sentAt)
}

private func questionAsk() -> WireItem {
    let ins = Instructable(v: 1, title: "Ask q", urgency: "today", steps: [
        Step(action: "Pick the target", question: Question(prompt: "Which?", choices: ["Staging", "Prod"])),
    ])
    let created = stamp(minutesAgo: 5)
    return WireItem(id: "q", title: "Ask q", status: "open", projectId: "Acme", created: created, updated: created,
                    payload: Payload(why: nil, cmd: nil, link: nil, instructable: ins))
}

@Suite @MainActor struct StoreAnswerEditingTests {
    @Test func changeBringsTheTextBackAndASendLeavesEditing() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let store = Store(defaults: defaults.defaults)
        let fake = FakeQueueSource(items: [textAsk], details: ["t": AskDetail(item: textAsk, events: [reply("t", "Kestrel 2.4")])])
        await start(store, fake)
        store.open("t")
        _ = await eventually { store.detail("t")?.replies.count == 1 }
        store.changeReply("t")
        #expect(store.editingReply == ["t"])
        #expect(store.drafts["t"] == "Kestrel 2.4")
        #expect(store.primaryAction(for: "t") == .done)   // the prefill alone sends nothing
        store.drafts["t"] = "Kestrel 2.5"
        #expect(store.primaryAction(for: "t") == .sendAndDone)
        #expect(await store.sendReply("t"))
        #expect(store.editingReply.isEmpty)
        #expect(await fake.replies["t"] == ["Kestrel 2.5"])
    }

    @Test func changeOnAChoicePicksTheLatestAndCancelGoesBack() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let store = Store(defaults: defaults.defaults)
        let fake = FakeQueueSource(items: [choiceAsk], details: ["c": AskDetail(item: choiceAsk, events: [reply("c", "choice: B")])])
        await start(store, fake)
        store.open("c")
        _ = await eventually { store.detail("c")?.latestSentChoice == 1 }
        store.changeReply("c")
        #expect(store.pendingChoice["c"] == 1)
        #expect(store.primaryAction(for: "c") == .done)
        store.cancelReplyChange("c")
        #expect(store.editingReply.isEmpty)
        #expect(store.pendingChoice["c"] == nil)

        store.changeReply("c")
        store.pendingChoice["c"] = 0
        #expect(await store.sendChoice("c"))
        #expect(store.editingReply.isEmpty)
        #expect(await fake.replies["c"] == ["choice: A"])
    }

    @Test func aFailedSendStaysInEditing() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let store = Store(defaults: defaults.defaults)
        let fake = FakeQueueSource(items: [textAsk], details: ["t": AskDetail(item: textAsk, events: [reply("t", "Kestrel 2.4")])])
        await start(store, fake)
        store.open("t")
        _ = await eventually { store.detail("t")?.replies.count == 1 }
        store.changeReply("t")
        store.drafts["t"] = "Kestrel 2.5"
        await fake.failNext(QueueError.unreachable("timed out"), on: "reply")
        #expect(!(await store.sendReply("t")))
        #expect(store.editingReply == ["t"])
        #expect(store.drafts["t"] == "Kestrel 2.5")
    }

    @Test func aStepAnswerChangeLeavesEditingOnceSent() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let store = Store(defaults: defaults.defaults)
        let ask = questionAsk()
        let fake = FakeQueueSource(items: [ask])
        await start(store, fake)
        store.open("q")
        store.answerDrafts["q"] = ["1": .picked(["Staging"])]
        #expect(await store.sendAnswers("q", only: ["1"]))

        store.changeAnswer("q", path: "1")
        #expect(store.editingAnswers["q"] == ["1"])
        store.answerDrafts["q"] = ["1": .picked(["Prod"])]
        store.cancelAnswerChange("q", path: "1")
        #expect(store.editingAnswers["q"] == nil)
        #expect(store.answerDrafts["q"] == nil)

        store.changeAnswer("q", path: "1")
        store.answerDrafts["q"] = ["1": .picked(["Prod"])]
        #expect(await store.sendAnswers("q", only: ["1"]))
        #expect(store.editingAnswers["q"] == nil)
        #expect(store.detail("q")?.model?.nodes.first?.answer?.picked == ["Prod"])
    }

    /// A reply from elsewhere (Telegram) during Change overtakes the untouched prefill:
    /// editing ends, so Done can't resend the old text over the newer answer.
    @Test func aReplyFromElsewhereEndsAnUntouchedChange() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let store = Store(defaults: defaults.defaults)
        let first = reply("t", "Kestrel 2.4")
        let fake = FakeQueueSource(items: [textAsk], details: ["t": AskDetail(item: textAsk, events: [first])])
        await start(store, fake)
        store.open("t")
        _ = await eventually { store.detail("t")?.replies.count == 1 }
        store.changeReply("t")
        let later = Event(seq: 2, itemId: "t", kind: "reply", actor: "owner", text: "Kestrel 3", at: sentAt)
        await fake.setDetail(AskDetail(item: textAsk, events: [first, later]))
        await store.refresh()
        _ = await eventually { store.detail("t")?.replies.count == 2 }
        #expect(store.editingReply.isEmpty)
        #expect(store.drafts["t"] == nil)
        #expect(store.primaryAction(for: "t") == .done)
        await store.sendAndDone("t")
        #expect(await fake.replies["t"] == nil)
    }

    @Test func aReplyFromElsewhereEndsAnUntouchedChoiceChangeButKeepsANewPick() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let store = Store(defaults: defaults.defaults)
        let first = reply("c", "choice: B")
        let fake = FakeQueueSource(items: [choiceAsk], details: ["c": AskDetail(item: choiceAsk, events: [first])])
        await start(store, fake)
        store.open("c")
        _ = await eventually { store.detail("c")?.latestSentChoice == 1 }
        store.changeReply("c")
        let second = Event(seq: 2, itemId: "c", kind: "reply", actor: "owner", text: "choice: A", at: sentAt)
        await fake.setDetail(AskDetail(item: choiceAsk, events: [first, second]))
        await store.refresh()
        _ = await eventually { store.detail("c")?.latestSentChoice == 0 }
        #expect(store.editingReply.isEmpty)
        #expect(store.pendingChoice["c"] == nil)
        #expect(store.primaryAction(for: "c") == .done)

        // A pick the owner made themselves survives the next arrival.
        store.changeReply("c")
        store.pendingChoice["c"] = 1
        let third = Event(seq: 3, itemId: "c", kind: "reply", actor: "owner", text: "note", at: sentAt)
        await fake.setDetail(AskDetail(item: choiceAsk, events: [first, second, third]))
        await store.refresh()
        _ = await eventually { store.detail("c")?.replies.count == 3 }
        #expect(store.editingReply == ["c"])
        #expect(store.pendingChoice["c"] == 1)
    }

    @Test func aSourceSwapForgetsEditing() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let store = Store(defaults: defaults.defaults)
        await start(store, FakeQueueSource(items: [textAsk]))
        store.editingReply = ["t"]
        store.editingAnswers = ["t": ["1"]]
        await start(store, FakeQueueSource(items: [textAsk]))
        #expect(store.editingReply.isEmpty)
        #expect(store.editingAnswers.isEmpty)
    }
}
