import RelayCore
import SwiftUI
import Testing
@testable import RelayUI

@Suite @MainActor struct ReplyComponentTests {
    /// Direction A: the words field opens under the selected choice, only when that choice takes words.
    @Test func fieldOnlyUnderSelectedWordChoice() {
        let placeholders: [String?] = ["What should change?", nil, "Why?"]
        #expect(OptionRows.fieldIndex(selected: [], placeholders: placeholders, multi: false) == nil)
        #expect(OptionRows.fieldIndex(selected: [0], placeholders: placeholders, multi: false) == 0)
        #expect(OptionRows.fieldIndex(selected: [1], placeholders: placeholders, multi: false) == nil)
        #expect(OptionRows.fieldIndex(selected: [2], placeholders: placeholders, multi: false) == 2)
        #expect(OptionRows.fieldIndex(selected: [0], placeholders: [], multi: false) == nil)
        #expect(OptionRows.fieldIndex(selected: [0], placeholders: placeholders, multi: true) == nil)
        #expect(OptionRows.fieldIndex(selected: [5], placeholders: placeholders, multi: false) == nil)
    }

    /// A question with a word choice is always option rows, never segments.
    @Test func segmentedFallsBackWithWords() {
        #expect(!AnswerDrafts.usesSegments(Question(prompt: "?", choices: [Choice("Mix", text: "What?"), "Keep"])))
        #expect(AnswerDrafts.usesSegments(Question(prompt: "?", choices: ["Mix", "Keep"])))
    }

    @Test func choiceSendsWithNewWords() {
        #expect(ChoiceGroup.canSend(picked: 0, latestSent: 0, sending: false, newWords: true))
        #expect(!ChoiceGroup.canSend(picked: 0, latestSent: 0, sending: true, newWords: true))
        #expect(ChoiceGroup.canSend(picked: nil, latestSent: 0, sending: false, newWords: true))
        #expect(!ChoiceGroup.canSend(picked: nil, latestSent: nil, sending: false, newWords: true))
    }

    @Test func captions() {
        #expect(ReplyBox.caption(.idle) == "Return to send · ⌥Return for a new line")
        #expect(ReplyBox.caption(.sending) == "Return to send · ⌥Return for a new line")
        #expect(ReplyBox.caption(.sent(at: "10:42")) == "Sent 10:42")
        #expect(ReplyBox.caption(.failed(reason: "timed out")) == "Couldn't send your reply. timed out")
    }

    @Test func replyCanSend() {
        #expect(ReplyBox.canSend(text: "C07", state: .idle))
        #expect(!ReplyBox.canSend(text: " \n ", state: .idle))
        #expect(!ReplyBox.canSend(text: "C07", state: .sending))
        #expect(ReplyBox.canSend(text: "C07", state: .failed(reason: "x")))
        #expect(ReplyBox.canSend(text: "C07", state: .sent(at: "10:42")))
    }

    @Test func choiceRules() {
        #expect(!ChoiceGroup.canSend(picked: nil, latestSent: nil, sending: false))
        #expect(ChoiceGroup.canSend(picked: 0, latestSent: nil, sending: false))
        #expect(!ChoiceGroup.canSend(picked: 0, latestSent: 0, sending: false))
        #expect(ChoiceGroup.canSend(picked: 1, latestSent: 0, sending: false))
        #expect(!ChoiceGroup.canSend(picked: 1, latestSent: 0, sending: true))
        #expect(ChoiceGroup.label(index: 0, choice: "Europe") == "1  Europe")
        #expect(ChoiceGroup.label(index: 5, choice: "a\nb") == "6  a⟨U+000A⟩b")
        #expect(ChoiceGroup.hint(count: 3) == "Press 1 to 3 to pick")
    }

    @Test func fromTitles() throws {
        let session = try #require(AskOrigin(from: Origin(session: "1b2c3d4e-0000-4000-8000-000000000001", host: "example-mac", cwd: "/work/acme")))
        #expect(FromDisclosure.title(session) == "From session 1b2c3d4e")
        let folderOnly = try #require(AskOrigin(from: Origin(cwd: "/work/acme")))
        #expect(FromDisclosure.title(folderOnly) == "From acme")
        let hostOnly = try #require(AskOrigin(from: Origin(host: "build\nmac")))
        #expect(FromDisclosure.title(hostOnly) == "From build⟨U+000A⟩mac")
    }

    @Test func fromRows() throws {
        let origin = try #require(AskOrigin(from: Origin(session: "1b2c3d4e-0000-4000-8000-000000000001", host: "example-mac", cwd: "/work/acme")))
        #expect(FromDisclosure.rows(origin).map(\.label) == ["Folder", "Host", "Session"])
        #expect(FromDisclosure.rows(origin).map(\.value) == ["/work/acme", "example-mac", "1b2c3d4e-0000-4000-8000-000000000001"])
        let partial = try #require(AskOrigin(from: Origin(host: "example-mac")))
        #expect(FromDisclosure.rows(partial).map(\.label) == ["Host"])
    }

    @Test func answeredRowAndHistoryWording() {
        #expect(AnsweredRow.accessibilityText(text: "You replied: Europe", time: "09:20") == "You replied: Europe, 09:20")
        #expect(AnsweredRow.accessibilityText(text: "You chose: Prod", time: "") == "You chose: Prod")
        #expect(DetailReply<FixturePanelModel>.historyTitle(earlier: 1) == "History · 1 earlier reply")
        #expect(DetailReply<FixturePanelModel>.historyTitle(earlier: 3) == "History · 3 earlier replies")
        #expect(!ReplyBox.canSend(text: "Kestrel 2.4", state: .idle, sentText: "Kestrel 2.4"))
        #expect(ReplyBox.canSend(text: "Kestrel 2.5", state: .idle, sentText: "Kestrel 2.4"))
    }
}

@Suite @MainActor struct QuestionWordsTests {
    /// Words past the cap under the picked word choice keep the question's Send off.
    @Test func sendIsOffOverTheWordsCap() {
        let question = Question(prompt: "How?", choices: [Choice("Mix", text: "What?"), "Keep"])
        var long = String(repeating: "a", count: 1001)
        let words = Binding(get: { long }, set: { long = $0 })
        let draft = Binding<AnswerDraft?>(get: { .picked(["Mix"]) }, set: { _ in })
        let over = StepQuestion(question: question, answer: nil, draft: draft, readOnly: false,
                                typedWords: long, words: words)
        #expect(over.wordsOver)
        #expect(!over.canSend)
        let keep = StepQuestion(question: question, answer: nil, draft: Binding(get: { .picked(["Keep"]) }, set: { _ in }),
                                readOnly: false, typedWords: long, words: words)
        #expect(!keep.wordsOver)
        #expect(keep.canSend)
    }
}
