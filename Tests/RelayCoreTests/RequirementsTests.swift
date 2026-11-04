import Foundation
import Testing
@testable import RelayCore

private let askID = "8b2e4c1a-3f5d-4e6a-9b7c-1d2e3f4a5b6c"
private let posted = "2026-11-04T09:00:00+00:00"

private func model(_ ins: Instructable, events: [Event] = []) -> DetailModel {
    let item = WireItem(id: askID, title: ins.title, status: "open", projectId: "Example", created: posted,
                        updated: posted, payload: Payload(instructable: ins))
    return DetailModel.make(item: item, events: events)
}

private func ask(_ steps: [Step], reply: ReplySpec? = nil, done: [String]? = nil) -> Instructable {
    var ins = Instructable(v: 1, title: "Rotate the staging deploy key", steps: steps, reply: reply)
    ins.done = done
    return ins
}

private func answerEvent(_ seq: Int, step: String, text: String) -> Event {
    let body = JSONValue.object(["step": .string(step), "text": .string(text)])
    return Event(seq: seq, itemId: askID, kind: "answer", actor: "owner",
                 text: String(decoding: body.data(), as: UTF8.self), at: posted)
}

private func ownerEvent(_ seq: Int, _ kind: String, _ text: String) -> Event {
    Event(seq: seq, itemId: askID, kind: kind, actor: "owner", text: text, at: posted)
}

private let question = Question(prompt: "Which environment?")
private let reply = ReplySpec(prompt: "Did the deploy pass?", choices: ["Yes", "No"])

@Suite struct RequirementsTests {
    // MARK: What counts as finished (RD 5)

    @Test func aRequiredLeafIsFinishedOnceTicked() {
        let m = model(ask([Step(action: "Open", id: "s1"), Step(action: "Rotate", required: true, id: "s2")]))
        let left = Requirements.state(m, ticks: [])
        #expect(left.items == [.step(path: "2", id: "s2")])
        #expect(left.left == [.step(path: "2", id: "s2")])
        #expect(left.hasAny && !left.ready)
        let done = Requirements.state(m, ticks: ["2"])
        #expect(done.left.isEmpty && done.ready)
    }

    @Test func aRequiredQuestionNeedsAnAnswerNotATick() {
        let ins = ask([Step(action: "Pick", question: question, required: true, id: "s1")])
        #expect(Requirements.state(model(ins), ticks: ["1"]).left == [.step(path: "1", id: "s1")])
        let answered = model(ins, events: [answerEvent(1, step: "1", text: "Staging")])
        #expect(Requirements.state(answered, ticks: []).ready)
    }

    @Test func aRequiredParentNeedsItsOwnAnswerAndEveryRequiredSubStep() {
        let parent = Step(action: "Rotate", substeps: [Step(action: "Copy", id: "s1.1"),
                                                       Step(action: "Note it", optional: true, id: "s1.2")],
                          question: question, required: true, id: "s1")
        let ins = ask([parent])
        // The optional sub-step left open never holds it back; its own question does.
        #expect(Requirements.state(model(ins), ticks: ["1.1"]).left == [.step(path: "1", id: "s1")])
        let answered = model(ins, events: [answerEvent(1, step: "1", text: "Staging")])
        #expect(Requirements.state(answered, ticks: ["1.1"]).ready)
        #expect(!Requirements.state(answered, ticks: []).ready)
    }

    @Test func aParentWithAnOptionalSubStepLeftOpenIsFinished() {
        let parent = Step(action: "Rotate", substeps: [Step(action: "Copy", id: "s1.1"),
                                                       Step(action: "Note it", optional: true, id: "s1.2")],
                          required: true, id: "s1")
        #expect(Requirements.state(model(ask([parent])), ticks: ["1.1"]).ready)
    }

    @Test func aRequiredSubStepIsMarkedOnItsOwn() {
        let parent = Step(action: "Rotate", substeps: [Step(action: "Copy", required: true, id: "s1.1"),
                                                       Step(action: "Paste", id: "s1.2")], id: "s1")
        let state = Requirements.state(model(ask([parent])), ticks: [])
        #expect(state.items == [.step(path: "1.1", id: "s1.1")])
        #expect(state.marks("1.1"))
        #expect(!state.marks("1") && !state.marks("1.2"))
    }

    // MARK: done

    @Test func doneStepsCoversEveryNonOptionalTopLevelStep() {
        let ins = ask([Step(action: "Open", id: "s1"),
                       Step(action: "Note", optional: true, id: "s2"),
                       Step(action: "Rotate", substeps: [Step(action: "Copy", id: "s3.1"),
                                                         Step(action: "Log", optional: true, id: "s3.2")],
                            required: true, id: "s3")],
                      done: ["steps"])
        let state = Requirements.state(model(ins), ticks: [])
        // Step 3 is required and covered by done: listed once. The optional step 2 never counts.
        #expect(state.items == [.step(path: "1", id: "s1"), .step(path: "3", id: "s3")])
        #expect(Requirements.state(model(ins), ticks: ["1", "3.1"]).ready)
    }

    @Test func doneReplyAndMessageWaitForTheOwnersEvents() {
        let ins = ask([Step(action: "Open", id: "s1")], reply: reply, done: ["reply", "message"])
        let none = Requirements.state(model(ins), ticks: [])
        #expect(none.items == [.reply, .message])
        #expect(none.marksReply && none.marksMessages)
        let replied = Requirements.state(model(ins, events: [ownerEvent(1, "reply", "Yes")]), ticks: [])
        #expect(replied.left == [.message])
        #expect(!replied.marksReply && replied.marksMessages)
        let both = Requirements.state(model(ins, events: [ownerEvent(1, "reply", "Yes"),
                                                          ownerEvent(2, "message", "Done on staging")]), ticks: [])
        #expect(both.ready && !both.marksReply && !both.marksMessages)
        // A session's message is never the owner's.
        let session = Event(seq: 1, itemId: askID, kind: "message", actor: "session", text: "hi", at: posted)
        #expect(Requirements.state(model(ins, events: [session]), ticks: []).left == [.reply, .message])
    }

    @Test func anAskWithoutRequirementsHasNone() {
        let state = Requirements.state(model(ask([Step(action: "Open", id: "s1")])), ticks: [])
        #expect(state == .none)
        #expect(!state.hasAny && state.ready)
        #expect(!state.marks("1") && !state.marksReply && !state.marksMessages)
    }

    @Test func marksClearPerItem() {
        let ins = ask([Step(action: "Open", required: true, id: "s1"), Step(action: "Rotate", required: true, id: "s2")],
                      done: ["message"])
        let one = Requirements.state(model(ins), ticks: ["1"])
        #expect(!one.marks("1") && one.marks("2") && one.marksMessages)
        let two = Requirements.state(model(ins), ticks: ["1", "2"])
        #expect(!two.marks("2") && two.marksMessages && !two.ready)
    }

    @Test func verifyIsNeverRequired() {
        var ins = ask([Step(action: "Open", id: "s1")], done: ["steps"])
        ins.verify = Step(action: "Check", required: true)
        let m = model(ins)
        #expect(m.nodes.last?.isVerify == true)
        #expect(m.nodes.last?.isRequired == false)
        #expect(Requirements.state(m, ticks: []).items == [.step(path: "1", id: "s1")])
    }

    // MARK: Drafts (RD 22)

    @Test func anUnsentAnswerCoveringTheLastRequiredQuestionTurnsDoneOn() {
        let ins = ask([Step(action: "Open", required: true, id: "s1"),
                       Step(action: "Pick", question: question, required: true, id: "s2"),
                       Step(action: "Other", question: Question(prompt: "Anything else?"), id: "s3")])
        let m = model(ins)
        let state = Requirements.state(m, ticks: ["1"])
        let covering = AnswerDrafts.unsent(["2": AnswerDraft.text("Staging")], nodes: m.nodes)
        #expect(!Requirements.doneAvailable(state, unsent: .none, replyUnsent: false))
        #expect(Requirements.doneAvailable(state, unsent: covering, replyUnsent: false))
        // An unsent answer to a question that isn't required changes nothing.
        let other = AnswerDrafts.unsent(["3": AnswerDraft.text("No")], nodes: m.nodes)
        #expect(!Requirements.doneAvailable(state, unsent: other, replyUnsent: false))
        // A tick is never covered by a draft.
        #expect(!Requirements.doneAvailable(Requirements.state(m, ticks: []), unsent: covering, replyUnsent: false))
    }

    @Test func aMessageLeftIsNeverCoveredByADraft() {
        let ins = ask([Step(action: "Pick", question: question, required: true, id: "s1")], reply: reply,
                      done: ["reply", "message"])
        let m = model(ins)
        let state = Requirements.state(m, ticks: [])
        let covering = AnswerDrafts.unsent(["1": AnswerDraft.text("Staging")], nodes: m.nodes)
        #expect(!Requirements.doneAvailable(state, unsent: covering, replyUnsent: true))
        let noMessage = ask([Step(action: "Pick", question: question, required: true, id: "s1")], reply: reply,
                            done: ["reply"])
        let n = model(noMessage)
        #expect(Requirements.doneAvailable(Requirements.state(n, ticks: []), unsent: covering, replyUnsent: true))
        #expect(!Requirements.doneAvailable(Requirements.state(n, ticks: []), unsent: covering, replyUnsent: false))
        #expect(Requirements.doneAvailable(.none, unsent: .none, replyUnsent: false))
    }

    // MARK: Progress

    @Test func deltaNamesStepIdsSortedAndLeavesOutPathsWithoutOne() {
        let parent = Step(action: "Rotate", substeps: [Step(action: "Copy", id: "b-copy"), Step(action: "Paste", id: "a-paste")],
                          id: "s2")
        var ins = ask([Step(action: "Open", id: "s1"), parent])
        ins.verify = Step(action: "Check")
        let nodes = model(ins).nodes
        let delta = Requirements.delta(nodes: nodes, before: ["1", "verify"], after: ["2.1", "2.2"])
        #expect(delta.tick == ["a-paste", "b-copy"])
        #expect(delta.untick == ["s1"])
        let legacy = model(ask([Step(action: "Open"), Step(action: "Rotate")])).nodes
        let none = Requirements.delta(nodes: legacy, before: [], after: ["1", "2"])
        #expect(none.tick.isEmpty && none.untick.isEmpty)
    }

    @Test func behindNamesTheTicksThePondLacks() {
        let parent = Step(action: "Rotate", substeps: [Step(action: "Copy", id: "s2.1"), Step(action: "Paste", id: "s2.2")],
                          required: true, id: "s2")
        let ins = ask([Step(action: "Open", required: true, id: "s1"), parent,
                       Step(action: "Ship", required: true, id: "s3")], done: ["message"])
        let nodes = model(ins).nodes
        let pond = [PondRequirement(kind: "step", id: "s1", path: "1"), PondRequirement(kind: "step", id: "s2", path: "2"),
                    PondRequirement(kind: "step", id: "s3", path: "3"), PondRequirement(kind: "message", id: nil, path: nil)]
        #expect(Requirements.behind(pond, nodes: nodes, ticks: ["1", "2.2"]) == ["s1", "s2.2"])
        #expect(Requirements.behind(pond, nodes: nodes, ticks: []).isEmpty)
        #expect(Requirements.behind([], nodes: nodes, ticks: ["1"]).isEmpty)
    }

    @Test func doneHelpSaysWhyDoneIsOff() {
        #expect(Requirements.doneHelp(.none) == "Done turns on once the marked items are finished. Skip always works.")
    }

    @Test func declaredReadsTheKeysWithoutAModel() {
        #expect(!Requirements.declared(ask([Step(action: "Open")])))
        #expect(Requirements.declared(ask([Step(action: "Open", required: true)])))
        #expect(Requirements.declared(ask([Step(action: "Open", substeps: [Step(action: "a", required: true)])])))
        #expect(Requirements.declared(ask([Step(action: "Open")], done: ["message"])))
        #expect(!Requirements.declared(ask([Step(action: "Open")], done: ["later"])))
        #expect(!Requirements.declared(nil))
    }
}

@Suite struct RequirementsModelTests {
    @Test func requiredAndDoneDecodeLeniently() throws {
        let json = #"""
        {"v":1,"title":"Rotate the staging deploy key","done":["steps",3,"later"],
         "steps":[{"do":"Open","required":"yes"},{"do":"Rotate","required":true},{"do":"Ship","required":false}]}
        """#
        let ins = try JSONDecoder().decode(Instructable.self, from: Data(json.utf8))
        #expect(ins.steps.map(\.required) == [nil, true, false])
        #expect(ins.done == ["steps", "later"])
        let m = model(ins)
        #expect(m.done == [.steps])
        let bad = try JSONDecoder().decode(Instructable.self, from: Data(
            #"{"v":1,"title":"t","done":"steps","steps":[{"do":"a"}]}"#.utf8))
        #expect(bad.done == nil)
    }

    @Test func requiredIsOnlyOnAStepThatIsNotOptional() {
        let ins = ask([Step(action: "Both", optional: true, required: true, id: "s1"),
                       Step(action: "Parent", substeps: [Step(action: "In", required: true, id: "s2.1")], optional: true,
                            id: "s2"),
                       Step(action: "Plain", required: true, id: "s3")])
        let nodes = model(ins).nodes
        #expect(nodes[0].content.required == false)
        #expect(nodes[0].isOptional)
        #expect(nodes[1].children[0].content.required == false)
        #expect(nodes[2].content.required == true)
        #expect(nodes[2].isRequired)
    }

    @Test func doneStepsMarksNonOptionalTopLevelNodes() {
        let ins = ask([Step(action: "Open", id: "s1"), Step(action: "Note", optional: true, id: "s2"),
                       Step(action: "Parent", substeps: [Step(action: "In", id: "s3.1")], id: "s3")], done: ["steps"])
        let nodes = model(ins).nodes
        #expect(nodes.map(\.isRequired) == [true, false, true])
        #expect(nodes[2].children[0].isRequired == false)
    }
}
