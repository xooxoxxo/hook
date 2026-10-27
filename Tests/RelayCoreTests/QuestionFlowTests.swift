import Foundation
import Testing
@testable import RelayCore

private let pick = Question(prompt: "Which environment?", choices: ["Staging", "Prod"])
private let free = Question(prompt: "Which region?")

/// 1 (asks), 2 asks + (2.1, 2.2 asks), 3, verify.
/// Items: 1, 2, 2.1, 2.2, 3, verify.
private func tree(answers: [String: Answer] = [:]) -> [DetailModel.Node] {
    DetailModel.nodes(
        steps: [
            Step(action: "Pick the target", question: pick),
            Step(action: "Prepare", substeps: [Step(action: "Tag it"), Step(action: "Name it", question: free)],
                 question: Question(prompt: "Ship today?", choices: ["Yes", "No"])),
            Step(action: "Open the dashboard"),
        ],
        verify: Step(action: "Check", question: free),
        answers: answers)
}

private func answer(_ step: String, seq: Int = 1) -> Answer {
    Answer(step: step, picked: ["Yes"], at: "2026-10-27T09:00:00+00:00", seq: seq)
}

@Suite struct QuestionFlowTests {
    @Test func nodesCarryQuestionsAndAnswers() {
        let nodes = tree(answers: ["1": answer("1"), "3": answer("3"), "verify": answer("verify")])
        #expect(nodes[0].question == pick)
        #expect(nodes[0].answer?.seq == 1)
        #expect(nodes[1].children[1].question == free)
        #expect(nodes[2].question == nil && nodes[2].answer == nil)       // no question: an answer is dropped
        #expect(nodes[3].isVerify && nodes[3].question == nil)            // verify never asks
    }

    @Test func itemsCountAParentsOwnQuestion() {
        #expect(Flow.items(of: tree()).map(\.path) == ["1", "2", "2.1", "2.2", "3", "verify"])
        #expect(Flow.tickable(tree()).map(\.path) == ["2.1", "3", "verify"])
    }

    @Test func aQuestionIsDoneOnlyOnceAnswered() {
        // Ticks on question nodes count for nothing.
        let ticked: Set<String> = ["1", "2.1", "2.2", "3"]
        #expect(Flow.progress(ticks: ticked, nodes: tree()) == StepProgress(done: 2, total: 6))
        #expect(Flow.currentStep(ticks: ticked, nodes: tree()) == "1")

        let answered = tree(answers: ["1": answer("1"), "2": answer("2")])
        #expect(Flow.progress(ticks: ["2.1"], nodes: answered) == StepProgress(done: 3, total: 6))
        #expect(Flow.currentStep(ticks: ["2.1"], nodes: answered) == "2.2")
        #expect(Flow.parentProgress(answered[1], ticks: ["2.1"]) == StepProgress(done: 2, total: 3))
        #expect(Flow.parentProgress(tree()[1], ticks: []) == StepProgress(done: 0, total: 3))
        #expect(Flow.state(of: answered[0], ticks: [], current: "2.2") == .done)
        #expect(Flow.state(of: tree()[0], ticks: ["1"], current: "1") == .current)
    }

    @Test func questionNodesCantBeTicked() {
        let nodes = tree()
        #expect(Flow.toggle(nodes[0], ticks: []) == [])
        #expect(Flow.toggle(nodes[1].children[1], ticks: []) == [])
        #expect(Flow.toggle(nodes[1], ticks: []) == ["2.1"])                  // only the sub-step without one
        #expect(Flow.toggle(nodes[1], ticks: ["2.1"]) == [])
        // ⌘T stops at an unanswered question and ticks nothing.
        let stopped = Flow.tickCurrent(ticks: [], nodes: nodes)
        #expect(stopped.ticks.isEmpty && stopped.path == nil)
        let answered = tree(answers: ["1": answer("1"), "2": answer("2")])
        let ticked = Flow.tickCurrent(ticks: [], nodes: answered)
        #expect(ticked.ticks == ["2.1"] && ticked.path == "2.1")
        let atQuestion = Flow.tickCurrent(ticks: ["2.1"], nodes: answered)
        #expect(atQuestion.ticks == ["2.1"] && atQuestion.path == nil)
        let unticked = Flow.untickLast(ticks: ["1", "2.1"], history: ["2.1", "1"], nodes: nodes)
        #expect(unticked.ticks == ["1"] && unticked.path == "2.1")
    }

    @Test func detailListsUnansweredPathsFromTheEvents() {
        let item = WireItem(
            id: "a1", title: "Ship Atlas", status: "open", created: "2026-10-27T09:00:00+00:00",
            updated: "2026-10-27T09:00:00+00:00",
            payload: Payload(instructable: Instructable(title: "Ship Atlas", steps: [
                Step(action: "Pick the target", question: pick),
                Step(action: "Prepare", substeps: [Step(action: "Tag it"), Step(action: "Name it", question: free)],
                     question: Question(prompt: "Ship today?", choices: ["Yes", "No"])),
            ])))
        let events = [
            Event(seq: 1, itemId: "a1", kind: "posted", actor: "session", at: "2026-10-27T09:00:00+00:00"),
            Event(seq: 2, itemId: "a1", kind: "answer", actor: "owner", text: #"{"step":"1","picked":["Staging"]}"#,
                  at: "2026-10-27T09:01:00+00:00"),
            Event(seq: 3, itemId: "a1", kind: "answer", actor: "owner", text: #"{"step":"1","picked":["Prod"]}"#,
                  at: "2026-10-27T09:02:00+00:00"),
        ]
        let model = DetailModel.make(item: item, events: events)
        #expect(model.nodes[0].answer?.picked == ["Prod"])
        #expect(model.unanswered == ["2", "2.2"])
        #expect(model.questionCount == 3)
        #expect(DetailModel.make(item: item, events: []).unanswered == ["1", "2", "2.2"])
    }
}
