import Foundation
import Testing
@testable import RelayCore

private let pick = Question(prompt: "Which environment?", choices: ["Staging", "Prod"])
private let many = Question(prompt: "Which flags?", choices: ["Search", "Exports", "Dark mode"], multi: true)
private let free = Question(prompt: "Which region?")

private func sent(_ step: String, picked: [String]? = nil, text: String? = nil) -> Answer {
    Answer(step: step, picked: picked, text: text, at: "2026-10-27T09:00:00+00:00", seq: 1)
}

/// 1 (pick), 2 parent asks (many) + 2.1, 2.2 (free), 3 plain.
private func tree(_ answers: [String: Answer] = [:]) -> [DetailModel.Node] {
    DetailModel.nodes(
        steps: [
            Step(action: "Pick", question: pick),
            Step(action: "Flags", substeps: [Step(action: "Tag"), Step(action: "Name", question: free)], question: many),
            Step(action: "Open"),
        ],
        verify: nil, answers: answers)
}

@Suite struct AnswerDraftsTests {
    @Test func unsentBuildsTheBatchInDocumentOrder() {
        let drafts: [String: AnswerDraft] = [
            "2.2": .text("  Use the EU region \n"),
            "1": .picked(["Prod"]),
            "2": .picked(["Exports", "Search"]),
        ]
        let unsent = AnswerDrafts.unsent(drafts, nodes: tree())
        #expect(unsent.paths == ["1", "2", "2.2"])
        #expect(unsent.batch == [
            Answers.entry(step: "1", picked: ["Prod"]),
            Answers.entry(step: "2", picked: ["Search", "Exports"]),     // choice order
            Answers.entry(step: "2.2", text: "Use the EU region"),      // trimmed
        ])
        #expect(unsent.count == 3)
    }

    @Test func blankEmptyEqualAndStrayDraftsAreNotUnsent() {
        let nodes = tree(["1": sent("1", picked: ["Prod"]), "2.2": sent("2.2", text: "EU")])
        let drafts: [String: AnswerDraft] = [
            "1": .picked(["Prod"]),       // equal to the sent answer
            "2": .picked([]),             // nothing picked
            "2.2": .text(" EU "),         // equal once trimmed
            "3": .text("no question here"),
        ]
        #expect(AnswerDrafts.unsent(drafts, nodes: nodes) == .none)
        #expect(AnswerDrafts.unsent(["2.2": .text("   ")], nodes: tree()) == .none)
        #expect(AnswerDrafts.unsent(["1": .picked(["Staging", "Prod"])], nodes: tree()) == .none)   // one pick only
    }

    @Test func aDraftOnAnUnansweredQuestionIsNotSent() {
        #expect(AnswerDrafts.isUnsent(.picked(["Staging"]), question: pick, answer: nil))
        #expect(AnswerDrafts.isUnsent(.picked(["Staging"]), question: pick, answer: sent("1", picked: ["Prod"])))
        #expect(!AnswerDrafts.isUnsent(.picked(["Prod"]), question: pick, answer: sent("1", picked: ["Prod"])))
        #expect(!AnswerDrafts.isUnsent(nil, question: pick, answer: nil))
    }

    @Test func settledDropsDraftsTheEventsShowAsSent() {
        let nodes = tree(["1": sent("1", picked: ["Prod"]), "2": sent("2", picked: ["Search"])])
        let drafts: [String: AnswerDraft] = [
            "1": .picked(["Prod"]),             // sent (a Telegram tap): goes
            "2": .picked(["Search", "Exports"]), // differs: stays
            "2.2": .text("EU"),                 // not answered yet: stays
            "3": .text("stray"),                // no question: goes
        ]
        #expect(AnswerDrafts.settled(drafts, nodes: nodes) == ["2": .picked(["Search", "Exports"]), "2.2": .text("EU")])
    }

    @Test func segmentsOnlyForShortSinglePicks() {
        #expect(AnswerDrafts.usesSegments(pick))
        #expect(AnswerDrafts.usesSegments(Question(prompt: "?", choices: ["A", "B", "Twelve chars"])))
        #expect(!AnswerDrafts.usesSegments(Question(prompt: "?", choices: ["A", "B", "Thirteen char"])))
        #expect(!AnswerDrafts.usesSegments(Question(prompt: "?", choices: ["A", "B", "C", "D"])))
        #expect(!AnswerDrafts.usesSegments(many))
        #expect(!AnswerDrafts.usesSegments(free))
    }

    @Test func wording() {
        #expect(AnswerDrafts.sendTitle(1) == "Send 1 answer")
        #expect(AnswerDrafts.sendTitle(2) == "Send 2 answers")
        #expect(AnswerDrafts.unansweredCaption(0) == nil)
        #expect(AnswerDrafts.unansweredCaption(1) == "1 question unanswered")
        #expect(AnswerDrafts.unansweredCaption(3) == "3 questions unanswered")
        #expect(AnswerDrafts.answeredText(sent("1", picked: ["Staging", "Prod"])) == "You chose: Staging, Prod")
        #expect(AnswerDrafts.answeredText(sent("4", text: "EU")) == "You answered: EU")
        #expect(AnswerDrafts.accessibilityAnswer(nil) == "Not answered.")
        #expect(AnswerDrafts.accessibilityAnswer(sent("1", picked: ["Prod"])) == "Answered: Prod.")
        let unsent = UnsentAnswers(paths: ["1"], batch: [Answers.entry(step: "1", picked: ["Prod"])])
        #expect(AnswerDrafts.uncovered(unanswered: ["1", "2.2"], unsent: unsent) == 1)
    }

    @Test func failureText() {
        #expect(AnswerDrafts.failureText(QueueError.askClosed) == "This ask is closed. Reopen it to change the answers.")
        let invalid = QueueError.rejected(status: 400, error: "invalid answers",
                                          details: ["answers[0].picked[0]: not one of the choices", "answers[1].step: answered twice"])
        #expect(AnswerDrafts.failureText(invalid) == "Hook couldn't send the answers. answers[0].picked[0]: not one of the choices")
        #expect(AnswerDrafts.failureText(QueueError.unreachable("timed out")) == "Couldn't send the answers. timed out")
    }

    @Test func primaryActionWithUnsentAnswers() {
        #expect(Flow.primaryAction(draft: nil, choice: nil, sent: nil, unsentAnswers: 2) == .sendAndDone)
        #expect(Flow.primaryAction(draft: nil, choice: nil, sent: nil, unsentAnswers: 0) == .done)
    }

    @Test func rowSummaryCountsAnswersOnlyWithTheDetail() {
        let ins = Instructable(v: 1, title: "Ask", steps: [
            Step(action: "Pick", question: pick),
            Step(action: "Flags", substeps: [Step(action: "Tag"), Step(action: "Name", question: free)], question: many),
            Step(action: "Open"),
        ])
        let item = WireItem(id: "q", title: "Ask", status: "open", projectId: "Acme", created: "2026-10-27T09:00:00+00:00",
                            updated: "2026-10-27T09:00:00+00:00", payload: Payload(why: nil, cmd: nil, link: nil, instructable: ins))
        // Items: 1, 2, 2.1, 2.2, 3.
        #expect(QueueLayout.itemCount(ins) == 5)
        #expect(QueueLayout.summary(for: item, ticked: ["2.1"]) == .steps(done: 1, total: 5))
        #expect(QueueLayout.summary(for: item, ticked: ["2.1", "1"], answered: ["1", "2", "9"]) == .steps(done: 3, total: 5))
        #expect(QueueLayout.summary(for: item, ticked: [], answered: []) == .steps(done: 0, total: 5))
    }
}
