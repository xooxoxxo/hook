import Foundation
import Testing
@testable import RelayCore

private func reply(_ seq: Int, _ text: String?, actor: String = "owner", kind: String = "reply",
                   at: String = "2026-10-16T09:12:00+00:00") -> Event {
    Event(seq: seq, itemId: "a", kind: kind, actor: actor, text: text, at: at)
}

@Suite struct ReplyTextTests {
    @Test func roundTrip() {
        #expect(ReplyText.wire(choice: "My account") == "choice: My account")
        #expect(ReplyText.choice(from: ReplyText.wire(choice: "My account")) == "My account")
        #expect(ReplyText.choice(from: "C07QX2") == nil)
        #expect(ReplyText.choice(from: "Choice: x") == nil)
    }

    @Test func display() {
        #expect(ReplyText.display("choice: My account") == "You chose: My account")
        #expect(ReplyText.display("choice: a\nb") == "You chose: a⟨U+000A⟩b")
        #expect(ReplyText.display("free\ntext") == "free\ntext")
    }

    @Test func sentChoicesComeFromOwnerReplies() {
        let choices = ["A", "B", "C"]
        let events = [reply(1, "choice: B"), reply(2, "choice: Z"), reply(3, "choice: A", actor: "session"),
                      reply(4, "hello"), reply(5, "choice: C", kind: "resolved"), reply(6, "choice: A")]
        #expect(ReplyText.sentChoices(events: events, choices: choices) == [0, 1])
        #expect(ReplyText.latestSentChoice(events: events, choices: choices) == 0)
        #expect(ReplyText.latestSentChoice(events: [reply(1, "hi")], choices: choices) == nil)
        #expect(ReplyText.sentChoices(events: [reply(1, "choice: A")], choices: []) == [])
    }

    @Test func linesAreOwnerRepliesOldestFirst() {
        let events = [reply(2, "choice: A", at: "2026-10-16T09:12:00+00:00"), reply(3, "nope", actor: "session"),
                      reply(5, "C07QX2", at: "2026-10-16T09:31:00+00:00"), reply(6, nil)]
        let lines = ReplyText.lines(events: events, locale: Locale(identifier: "en_GB"), timeZone: TimeZone(identifier: "UTC")!)
        #expect(lines == [ReplyLine(id: 2, text: "You chose: A", time: "09:12", choice: "A"), ReplyLine(id: 5, text: "C07QX2", time: "09:31")])
    }

    // MARK: Words on a choice (Pond 1.4.0)

    @Test func wireWithWords() {
        #expect(ReplyText.separator == " \u{00B7} ")
        #expect(ReplyText.wire(choice: "Mix", words: " Staff Monday ") == "choice: Mix · Staff Monday")
        #expect(ReplyText.wire(choice: "Mix", words: "line one\nline two\n") == "choice: Mix · line one\nline two")
    }

    @Test func wireEmptyWords() {
        #expect(ReplyText.wire(choice: "Mix", words: nil) == "choice: Mix")
        #expect(ReplyText.wire(choice: "Mix", words: "") == "choice: Mix")
        #expect(ReplyText.wire(choice: "Mix", words: " \n ") == "choice: Mix")
    }

    @Test func parsePrefersLongestLabel() {
        let choices = ["Mix", "Mix it"]
        #expect(ReplyText.parse("choice: Mix it · now", choices: choices)! == (1, "now"))
        #expect(ReplyText.parse("choice: Mix · now", choices: choices)! == (0, "now"))
        #expect(ReplyText.parse("choice: Mix it", choices: choices)! == (1, nil))
        #expect(ReplyText.parse("choice: Mix", choices: choices)! == (0, nil))
        #expect(ReplyText.parse("choice: Mixed", choices: choices) == nil)
        #expect(ReplyText.parse("Mix", choices: choices) == nil)
        #expect(ReplyText.parse("choice: Mix · ", choices: choices) == nil)
    }

    @Test func parseLabelWithSeparator() {
        #expect(ReplyText.parse("choice: A · B · c", choices: ["A · B"])! == (0, "c"))
        #expect(ReplyText.parse("choice: A · B", choices: ["A · B"])! == (0, nil))
        #expect(ReplyText.parse("choice: A · B", choices: ["A"])! == (0, "B"))
        #expect(ReplyText.parse("choice: A · two\nlines", choices: ["A"])! == (0, "two\nlines"))
    }

    @Test func sentChoicesCountsWordReplies() {
        let choices = ["No", "Yes"]
        let events = [reply(1, "choice: Yes · Tell the night shift first"), reply(2, "choice: No")]
        #expect(ReplyText.sentChoices(events: events, choices: choices) == [0, 1])
        #expect(ReplyText.latestSentChoice(events: events, choices: choices) == 0)
        #expect(ReplyText.latestSentChoice(events: [events[0]], choices: choices) == 1)
        #expect(ReplyText.display("choice: Yes · Tell the night shift first") == "You chose: Yes · Tell the night shift first")
    }
}
