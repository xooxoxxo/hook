import Foundation
import RelayCore
import Testing

private let text = ReplyLine(id: 1, text: "Kestrel 2.4", time: "09:12")
private let choice = ReplyLine(id: 2, text: "You chose: Europe", time: "09:20", choice: "Europe")
private let pick = Question(prompt: "Which?", choices: ["Staging", "Prod"])

@Suite struct AnswerEditingTests {
    @Test func theReplyFoldsOnlyWhenSentAndNothingWaits() {
        #expect(!AnswerEditing.showsReplyAnswer(replies: [], editing: false, draft: nil, pick: nil))
        #expect(AnswerEditing.showsReplyAnswer(replies: [text], editing: false, draft: nil, pick: nil))
        #expect(AnswerEditing.showsReplyAnswer(replies: [text], editing: false, draft: "  ", pick: nil))
        #expect(!AnswerEditing.showsReplyAnswer(replies: [text], editing: true, draft: nil, pick: nil))
        #expect(!AnswerEditing.showsReplyAnswer(replies: [text], editing: false, draft: "more", pick: nil))
        #expect(!AnswerEditing.showsReplyAnswer(replies: [choice], editing: false, draft: nil, pick: 1))
    }

    @Test func repliedTextAndPrefill() {
        #expect(AnswerEditing.repliedText(choice) == "You replied: Europe")
        #expect(AnswerEditing.repliedText(text) == "You replied: Kestrel 2.4")
        #expect(AnswerEditing.latestText([choice, text]) == "Kestrel 2.4")
        #expect(AnswerEditing.latestText([text, choice]) == nil)
        #expect(AnswerEditing.replyPrefill(replies: [text], hasChoices: false, latestSentChoice: nil) == ("Kestrel 2.4", nil))
        #expect(AnswerEditing.replyPrefill(replies: [choice], hasChoices: true, latestSentChoice: 0) == (nil, 0))
    }

    @Test func thePrefilledTextIsNotUnsent() {
        #expect(!AnswerEditing.isNewText(" Kestrel 2.4 ", sentText: "Kestrel 2.4"))
        #expect(AnswerEditing.isNewText("Kestrel 2.5", sentText: "Kestrel 2.4"))
        #expect(!AnswerEditing.isNewText("  ", sentText: nil))
        #expect(Flow.primaryAction(draft: "Kestrel 2.4", choice: nil, sent: nil, sentText: "Kestrel 2.4") == .done)
        #expect(Flow.primaryAction(draft: "Kestrel 2.5", choice: nil, sent: nil, sentText: "Kestrel 2.4") == .sendAndDone)
    }

    @Test func aStepQuestionFoldsWhenAnsweredAndUnchanged() {
        let answer = Answer(step: "1", picked: ["Prod"], at: "2026-10-16T09:12:00+00:00", seq: 1)
        func shows(_ answer: Answer?, _ draft: AnswerDraft? = nil, editing: Bool = false, readOnly: Bool = false) -> Bool {
            AnswerEditing.showsStepAnswer(question: pick, answer: answer, draft: draft, editing: editing, readOnly: readOnly)
        }
        #expect(shows(answer))
        #expect(shows(answer, .picked(["Prod"])))      // a draft equal to the answer is nothing unsent
        #expect(!shows(answer, .picked(["Staging"])))  // "Not sent" keeps the control
        #expect(!shows(answer, editing: true))
        #expect(!shows(nil))
        #expect(!shows(answer, readOnly: true))        // a closed ask keeps its read-only line
    }
}
