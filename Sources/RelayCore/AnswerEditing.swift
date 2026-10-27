import Foundation

/// The answered state: once a reply or a step answer is sent, its question folds into an
/// answer row with Change. Change brings the question back prefilled; a send posts a new
/// reply or answer (the latest wins) and leaves editing. Editing is memory only, and
/// nothing about it reaches the protocol.
public enum AnswerEditing {
    /// The line beside Change.
    public static let changeNote = "Changing sends a new reply; the agent may already have acted on the first."

    /// The ask's reply shows as its answer row: a reply was sent, the owner isn't changing
    /// it, and no typed text or picked choice is waiting (a key pick reopens the question).
    public static func showsReplyAnswer(replies: [ReplyLine], editing: Bool, draft: String?, pick: Int?) -> Bool {
        guard !replies.isEmpty, !editing, pick == nil else { return false }
        return (draft ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// "You replied: Staging": a choice reply by its choice, free text raw (the view runs prose()).
    public static func repliedText(_ reply: ReplyLine) -> String {
        "You replied: " + (reply.choice ?? reply.text)
    }

    /// The latest reply's text when it was free text; nil after a choice or no reply.
    public static func latestText(_ replies: [ReplyLine]) -> String? {
        guard let last = replies.last, last.choice == nil else { return nil }
        return last.text
    }

    /// What Change puts back: the latest sent choice for an ask with choices, else the
    /// latest free text as the draft.
    public static func replyPrefill(replies: [ReplyLine], hasChoices: Bool, latestSentChoice: Int?)
        -> (draft: String?, choice: Int?) {
        hasChoices ? (nil, latestSentChoice) : (latestText(replies), nil)
    }

    /// A reply arrived from elsewhere (Telegram, the CLI) while the owner was changing the
    /// reply, and the draft and pick are still what Change put back: that prefill is now
    /// out of date, so editing ends and it goes. Sending it would override the newer reply.
    /// A draft or pick the owner changed stays.
    public static func changeWentStale(before: [ReplyLine], after: [ReplyLine], draft: String?, pick: Int?,
                                       sentChoiceBefore: Int?) -> Bool {
        guard after.count > before.count else { return false }
        let text = (draft ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let untouchedText = text.isEmpty || text == latestText(before)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let untouchedPick = pick == nil || pick == sentChoiceBefore
        return untouchedText && untouchedPick
    }

    /// Text that would send something: not blank, and not the latest sent text.
    public static func isNewText(_ text: String, sentText: String?) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return trimmed != sentText?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A step question shows only its answered row and Change: it has a sent answer, no
    /// unsent draft, and isn't being changed. A closed ask keeps its read-only line instead.
    public static func showsStepAnswer(question: Question, answer: Answer?, draft: AnswerDraft?, editing: Bool,
                                       readOnly: Bool) -> Bool {
        guard !readOnly, answer != nil, !editing else { return false }
        return !AnswerDrafts.isUnsent(draft, question: question, answer: answer)
    }
}
