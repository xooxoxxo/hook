import Foundation
import RelayCore
import Testing
@testable import RelayUI

private let environment = Question(prompt: "Which environment?", choices: ["Staging", "Prod"])
private let region = Question(prompt: "Which region?")
private let ship = Question(prompt: "Ship today?", choices: ["Yes", "No"])

/// "q": 1 asks (pick), 2 plain, 3 asks (text); a free-text reply.
private func questionItem(_ id: String = "q", reply: ReplySpec? = ReplySpec(prompt: "Anything else?")) -> WireItem {
    let ins = Instructable(v: 1, title: "Ask \(id)", urgency: "today", steps: [
        Step(action: "Pick the target", question: environment),
        Step(action: "Run the deploy", code: "kestrel deploy"),
        Step(action: "Name the region", question: region),
    ], reply: reply)
    let created = stamp(minutesAgo: 5)
    return WireItem(id: id, title: "Ask \(id)", status: "open", projectId: "Acme", created: created, updated: created,
                    payload: Payload(why: nil, cmd: nil, link: nil, instructable: ins))
}

/// "p": 1 a parent that asks, with a coded sub-step and a plain one; 2 plain.
private func parentItem() -> WireItem {
    let ins = Instructable(v: 1, title: "Ask p", urgency: "today", steps: [
        Step(action: "Prepare", code: "kestrel prepare",
             substeps: [Step(action: "Tag it", code: "git tag v1"), Step(action: "Post it")], question: ship),
        Step(action: "Roll out"),
    ])
    let created = stamp(minutesAgo: 6)
    return WireItem(id: "p", title: "Ask p", status: "open", projectId: "Acme", created: created, updated: created,
                    payload: Payload(why: nil, cmd: nil, link: nil, instructable: ins))
}

private func answerEvent(_ id: String, seq: Int, _ entry: JSONValue) -> Event {
    Event(seq: seq, itemId: id, kind: "answer", actor: "owner", text: String(decoding: entry.data(), as: UTF8.self),
          at: "2026-10-16T09:12:00+00:00")
}

@MainActor private final class Copied {
    var values: [String] = []
}

@Suite @MainActor struct StoreAnswersTests {
    @Test func draftsCountAndSendAsOneBatch() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let store = Store(defaults: defaults.defaults)
        let fake = FakeQueueSource(items: [questionItem()])
        await start(store, fake)
        store.open("q")
        #expect(store.unsentAnswers(for: "q") == .none)
        store.answerDrafts["q"] = ["3": .text("  EU  "), "1": .picked(["Prod"])]
        #expect(store.unsentAnswers(for: "q").count == 2)
        #expect(store.primaryAction(for: "q") == .sendAndDone)
        #expect(store.detail("q")?.unsent.count == 2)

        #expect(await store.sendAnswers("q"))
        #expect(await fake.answers["q"] == [[Answers.entry(step: "1", picked: ["Prod"]), Answers.entry(step: "3", text: "EU")]])
        #expect(store.answerDrafts["q"] == nil)
        #expect(store.answerStates["q"] == nil)
        #expect(store.unsentAnswers(for: "q") == .none)
        // Refetched: the detail shows both answered, and nothing else is unanswered.
        let snapshot = store.detail("q")
        #expect(snapshot?.model?.unanswered == [])
        #expect(snapshot?.unansweredCaption == nil)
        #expect(store.pending.isEmpty)   // answers leave the ask open
    }

    @Test func aSecondSendWhileOneRunsIsBlocked() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let store = Store(defaults: defaults.defaults)
        let fake = FakeQueueSource(items: [questionItem()])
        await start(store, fake)
        store.answerDrafts["q"] = ["1": .picked(["Staging"])]
        async let first = store.sendAnswers("q")
        async let second = store.sendAnswers("q")
        let results = await [first, second]
        #expect(results.filter { $0 }.count == 1)
        #expect(await fake.count("answer") == 1)
    }

    @Test func sendAndDoneSendsAnswersThenTheReplyThenCloses() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let store = Store(defaults: defaults.defaults)
        let fake = FakeQueueSource(items: [questionItem()])
        await start(store, fake)
        store.open("q")
        store.answerDrafts["q"] = ["1": .picked(["Prod"])]
        store.drafts["q"] = "All set"
        await store.sendAndDone("q")
        let calls = await fake.calls.filter { $0.hasPrefix("answer") || $0.hasPrefix("reply") }
        #expect(calls == ["answer q", "reply q"])
        #expect(store.pending.contains("q"))
        #expect(store.drafts["q"] == nil)
        #expect(store.answerDrafts["q"] == nil)
    }

    @Test func sendAndDoneWithOnlyAnswers() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let store = Store(defaults: defaults.defaults)
        let fake = FakeQueueSource(items: [questionItem()])
        await start(store, fake)
        store.open("q")
        store.answerDrafts["q"] = ["3": .text("EU")]
        #expect(store.keyContext(textFieldFocused: false, popoverOpen: false, closedHeaderFocused: false).hasUnsentAnswers)
        await store.sendAndDone("q")
        #expect(await fake.count("reply") == 0)
        #expect(store.pending.contains("q"))
    }

    @Test func aFailedAnswersSendStopsSendAndDone() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let store = Store(defaults: defaults.defaults)
        let fake = FakeQueueSource(items: [questionItem()])
        await start(store, fake)
        store.open("q")
        await fake.failNext(QueueError.unreachable("timed out"), on: "answer")
        store.answerDrafts["q"] = ["1": .picked(["Prod"])]
        store.drafts["q"] = "All set"
        await store.sendAndDone("q")
        #expect(await fake.count("reply") == 0)
        #expect(store.pending.isEmpty)
        #expect(store.navigation.selectedID == "q")
        #expect(store.answerDrafts["q"] == ["1": .picked(["Prod"])])
        #expect(store.answerStates["q"] == .failed(reason: "Couldn't send the answers. timed out"))
        #expect(store.detail("q")?.answerState == .failed(reason: "Couldn't send the answers. timed out"))
    }

    @Test func invalidAnswersShowTheFirstDetail() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let store = Store(defaults: defaults.defaults)
        let fake = FakeQueueSource(items: [questionItem()])
        await start(store, fake)
        await fake.failNext(QueueError.rejected(status: 400, error: "invalid answers",
                                                details: ["answers[0].picked[0]: not one of the choices"]), on: "answer")
        store.answerDrafts["q"] = ["1": .picked(["Prod"])]
        #expect(!(await store.sendAnswers("q")))
        #expect(store.answerStates["q"] == .failed(reason: "Hook couldn't send the answers. answers[0].picked[0]: not one of the choices"))
    }

    @Test func aClosedAskIsReadOnly() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let store = Store(defaults: defaults.defaults)
        let item = questionItem()
        let fake = FakeQueueSource(items: [item])
        await start(store, fake)
        store.open("q")
        store.answerDrafts["q"] = ["1": .picked(["Prod"])]
        // The session closed it, and this Mac hasn't listed since: the source refuses (409).
        await fake.setItems([])
        await fake.setClosed([closed(item)])
        #expect(!(await store.sendAnswers("q")))
        #expect(store.answerStates["q"] == .failed(reason: "This ask is closed. Reopen it to change the answers."))
        // Once the Store knows it is closed, nothing is unsent and ⌘S / ⌘↩ do nothing.
        await store.refresh()
        await store.focus("q")
        #expect(store.unsentAnswers(for: "q") == .none)
        let context = store.keyContext(textFieldFocused: false, popoverOpen: false, closedHeaderFocused: false)
        #expect(!context.hasUnsentAnswers)
        #expect(KeyMap.command(for: .cmdS, in: context) == nil)
        #expect(store.detail("q")?.unansweredCaption == nil)
    }

    @Test func aTelegramTapThatMatchesTheDraftDropsIt() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let store = Store(defaults: defaults.defaults)
        let item = questionItem()
        let fake = FakeQueueSource(items: [item])
        await start(store, fake)
        store.answerDrafts["q"] = ["1": .picked(["Prod"]), "3": .text("EU")]
        await fake.setDetail(AskDetail(item: item, events: [answerEvent("q", seq: 1, Answers.entry(step: "1", picked: ["Prod"]))]))
        await store.focus("q")
        #expect(store.answerDrafts["q"] == ["3": .text("EU")])
    }

    @Test func theCaptionCountsUnansweredQuestionsWithoutADraft() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let store = Store(defaults: defaults.defaults)
        await start(store, FakeQueueSource(items: [questionItem()]))
        store.open("q")
        #expect(store.detail("q")?.unansweredCaption == "2 questions unanswered")
        store.answerDrafts["q"] = ["1": .picked(["Prod"])]
        #expect(store.detail("q")?.unansweredCaption == "1 question unanswered")
        #expect(store.detail("q")?.primary == .sendAndDone)
    }

    // The four slice 2 concerns.

    @Test func tickCurrentSeesAnswers() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let store = Store(defaults: defaults.defaults)
        let item = questionItem()
        let fake = FakeQueueSource(items: [item])
        await fake.setDetail(AskDetail(item: item, events: [answerEvent("q", seq: 1, Answers.entry(step: "1", picked: ["Prod"]))]))
        await start(store, fake)
        store.open("q")
        // Step 1 is answered, so ⌘T ticks step 2 instead of stopping on the question.
        #expect(store.tickCurrent(in: "q") == "2")
        // Step 3 asks and is unanswered: ⌘T stops there.
        #expect(store.tickCurrent(in: "q") == nil)
    }

    @Test func theCurrentItemCanBeAParentsOwnQuestion() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let store = Store(defaults: defaults.defaults)
        let copied = Copied()
        store.shell = PanelShellActions(hide: {}, setUp: {}, quit: {}, dock: { _ in }, openSettings: { _ in },
                                        copy: { copied.values.append($0) }, openURL: { _ in })
        await start(store, FakeQueueSource(items: [parentItem()]))
        store.open("p")
        store.perform(.copyCurrentCode)
        #expect(copied.values == ["kestrel prepare"])
    }

    @Test func aParentWithAnOpenQuestionDoesNotCollapse() {
        let nodes = DetailModel.make(item: parentItem(), events: []).nodes
        let ticks: Set<String> = ["1.1", "1.2"]
        let current = Flow.currentStep(ticks: ticks, nodes: nodes)
        #expect(current == "1")
        let rotor = DetailSteps<FixturePanelModel>.rotorNodes(nodes, ticks: ticks, current: current, expanded: [])
        #expect(rotor.map(\.path) == ["1", "1.1", "1.2", "2"])
        let answered = DetailModel.make(item: parentItem(), events: [answerEvent("p", seq: 1, Answers.entry(step: "1", picked: ["Yes"]))]).nodes
        let collapsed = DetailSteps<FixturePanelModel>.rotorNodes(answered, ticks: ticks, current: "2", expanded: [])
        #expect(collapsed.map(\.path) == ["1", "2"])
    }

    @Test func theQueueRowCountsAnswersOnceTheDetailIsCached() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let store = Store(defaults: defaults.defaults)
        let item = questionItem()
        let fake = FakeQueueSource(items: [item])
        await start(store, fake)
        #expect(store.queue.rows["q"]?.summary == .steps(done: 0, total: 3))
        store.answerDrafts["q"] = ["1": .picked(["Prod"])]
        #expect(await store.sendAnswers("q"))
        #expect(store.queue.rows["q"]?.summary == .steps(done: 1, total: 3))
        // A later list keeps the count (the answers come from the cached detail, not the list).
        await store.refresh()
        #expect(store.queue.rows["q"]?.summary == .steps(done: 1, total: 3))
    }
}
