import Foundation

/// The owner's unsent answer to one step question: picks (in choice order) or text.
/// Drafts live in memory only, keyed by ask id and step path, like reply drafts.
public enum AnswerDraft: Equatable, Sendable {
    case picked([String])
    case text(String)
}

/// An answers send in flight, or why the last one failed.
public enum AnswerSendState: Equatable, Sendable {
    case sending
    case failed(reason: String)
}

/// The answers the open ask would send now, in document order.
public struct UnsentAnswers: Equatable, Sendable {
    /// The step paths, one per entry of `batch`.
    public var paths: [String]
    /// What `QueueSource.answer` takes (`Answers.entry`).
    public var batch: [JSONValue]

    public init(paths: [String] = [], batch: [JSONValue] = []) {
        self.paths = paths
        self.batch = batch
    }

    public static let none = UnsentAnswers()
    public var count: Int { batch.count }
}

/// The rules for answer drafts: what counts as unsent, what a send carries, and the words
/// the question block and bottom bar show.
public enum AnswerDrafts {
    /// How long the owner's words on a choice may be (Pond 1.4.0's `answers[i].text` cap; the
    /// reply's words are held to it here, as the Pond doesn't cap reply text).
    public static let wordsLimit = 1000

    /// "Trim N characters to send." when `words` run past `wordsLimit`; nil otherwise.
    /// Counted in Unicode scalars, as the Pond counts.
    public static func wordsOver(_ words: String) -> String? {
        TalkLimits.over(words.unicodeScalars.count, limit: wordsLimit)
    }

    /// The words a draft sends: `typed`, trimmed, with a single pick of a choice that takes
    /// words; nil when blank, or for any other draft.
    public static func words(_ typed: String?, for draft: AnswerDraft?, question: Question) -> String? {
        guard case .picked(let picks)? = draft, picks.count == 1,
              let index = question.options.firstIndex(of: picks[0]), question.placeholder(at: index) != nil
        else { return nil }
        let trimmed = typed?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The words sent with a pick (`Answer.text` beside `picked`); nil for none or free text.
    public static func sentWords(_ answer: Answer?) -> String? {
        answer?.picked == nil ? nil : answer?.text
    }

    /// The draft as it would be sent: text trimmed; nil when there is nothing to send
    /// (no picks, blank text, or a draft of the wrong kind for the question).
    public static func sendable(_ draft: AnswerDraft, question: Question) -> AnswerDraft? {
        switch draft {
        case .picked(let picks):
            guard !question.isFreeText, !picks.isEmpty else { return nil }
            let ordered = question.options.filter(picks.contains)
            guard !ordered.isEmpty, question.allowsMany || ordered.count == 1 else { return nil }
            return .picked(ordered)
        case .text(let text):
            guard question.isFreeText else { return nil }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : .text(trimmed)
        }
    }

    /// The sent answer as a draft, for comparing and as a control's starting value.
    public static func draft(of answer: Answer?) -> AnswerDraft? {
        guard let answer else { return nil }
        if let picked = answer.picked { return .picked(picked) }
        return answer.text.map(AnswerDraft.text)
    }

    /// A draft that would send something other than the sent answer: "Not sent".
    /// That includes a draft on a question nobody has answered yet. `words` are those typed
    /// under the question's word choice (nil: untouched, so the sent words stand); new words on
    /// the sent pick are unsent without a draft.
    public static func isUnsent(_ draft: AnswerDraft?, question: Question, answer: Answer?,
                                words: String? = nil) -> Bool {
        guard let draft = draft ?? (words != nil ? Self.draft(of: answer) : nil),
              let ready = sendable(draft, question: question) else { return false }
        let sent = Self.draft(of: answer).flatMap { sendable($0, question: question) }
        if ready != sent { return true }
        let sentWords = sentWords(answer)
        return Self.words(words ?? sentWords, for: ready, question: question)
            != Self.words(sentWords, for: sent, question: question)
    }

    /// The batch to send: every question node (document order) whose draft is unsent.
    /// `locked` paths (Flow.lockedPaths) are never sent; `only`, when given, limits the
    /// batch to those paths (one question's own Send).
    /// `words` are those typed under each question's word choice, by path: a pick of a word
    /// choice sends them beside it (`Answers.entry(step:picked:words:)`).
    public static func unsent(_ drafts: [String: AnswerDraft], nodes: [DetailModel.Node], locked: Set<String> = [],
                              only: Set<String>? = nil, words: [String: String] = [:]) -> UnsentAnswers {
        guard !drafts.isEmpty || !words.isEmpty else { return .none }
        var result = UnsentAnswers()
        for node in Flow.flattened(nodes) {
            let typed = words[node.path]
            guard !locked.contains(node.path), only?.contains(node.path) ?? true,
                  let question = node.question,
                  let draft = drafts[node.path] ?? (typed != nil ? draft(of: node.answer) : nil),
                  isUnsent(draft, question: question, answer: node.answer, words: typed),
                  let ready = sendable(draft, question: question) else { continue }
            result.paths.append(node.path)
            switch ready {
            case .picked(let picks):
                let sending = Self.words(typed ?? sentWords(node.answer), for: ready, question: question)
                result.batch.append(Answers.entry(step: node.path, picked: picks, words: sending))
            case .text(let text): result.batch.append(Answers.entry(step: node.path, text: text))
            }
        }
        return result
    }

    /// The drafts still worth keeping: a draft equal to the sent answer (sent from here, or
    /// by a Telegram tap) goes, and so does one for a path that no longer asks.
    /// A draft whose typed `words` differ from those sent stays.
    public static func settled(_ drafts: [String: AnswerDraft], nodes: [DetailModel.Node],
                               words: [String: String] = [:]) -> [String: AnswerDraft] {
        guard !drafts.isEmpty else { return drafts }
        let asking = Dictionary(Flow.flattened(nodes).filter(\.asks).map { ($0.path, $0) }) { first, _ in first }
        return drafts.filter { path, draft in
            guard let node = asking[path], let question = node.question else { return false }
            guard let sent = node.answer else { return true }
            guard sendable(draft, question: question) != nil else { return true }
            return isUnsent(draft, question: question, answer: sent, words: words[path])
        }
    }

    /// The unanswered questions no unsent draft covers.
    public static func uncovered(unanswered: [String], unsent: UnsentAnswers) -> Int {
        let covered = Set(unsent.paths)
        return unanswered.filter { !covered.contains($0) }.count
    }

    /// The bottom bar's caption (R6); nil when every question is answered or drafted.
    public static func unansweredCaption(_ count: Int) -> String? {
        switch count {
        case ..<1: return nil
        case 1: return "1 question unanswered"
        default: return "\(count) questions unanswered"
        }
    }

    /// The draft after the owner picks option `index` (an option row, click or key): a
    /// single pick replaces the pick; a multi pick flips that choice, the picks kept in choice
    /// order. nil for a free-text question or an index out of range.
    public static func pick(_ index: Int, in question: Question, picks: [String]) -> AnswerDraft? {
        let options = question.options
        guard !question.isFreeText, options.indices.contains(index) else { return nil }
        let choice = options[index]
        guard question.allowsMany else { return .picked([choice]) }
        var set = Set(picks)
        if set.contains(choice) { set.remove(choice) } else { set.insert(choice) }
        return .picked(options.filter(set.contains))
    }

    /// "Send 1 answer", "Send 2 answers".
    public static func sendTitle(_ count: Int) -> String {
        count == 1 ? "Send 1 answer" : "Send \(count) answers"
    }

    /// The answered line, raw (the view sanitizes it): "You chose: Staging, Prod" or
    /// "You answered: <text>".
    public static func answeredText(_ answer: Answer) -> String {
        if let picked = answer.picked {
            return "You chose: " + picked.joined(separator: ", ") + (answer.text.map { ReplyText.separator + $0 } ?? "")
        }
        return "You answered: " + (answer.text ?? "")
    }

    /// For VoiceOver: "Answered: Staging, Prod." / "Answered: <text>." / "Not answered."
    public static func accessibilityAnswer(_ answer: Answer?) -> String {
        guard let answer else { return "Not answered." }
        let value = answer.picked.map { $0.joined(separator: ", ") + (answer.text.map { ", " + $0 } ?? "") }
            ?? answer.text ?? ""
        return "Answered: \(value)."
    }

    /// A single pick shows as a segmented control when it has at most 3 choices of at most
    /// 12 characters each; otherwise as a radio group.
    public static func usesSegments(_ question: Question) -> Bool {
        !question.isFreeText && !question.allowsMany && !question.hasWords && question.options.count <= 3
            && question.options.allSatisfy { $0.count <= 12 }
    }

    /// The bottom bar's error line for a failed answers send.
    public static func failureText(_ error: any Error) -> String {
        if let queue = error as? QueueError {
            switch queue {
            case .askClosed:
                return UserFacingError.text(queue)
            case .rejected(400, "invalid answers", let details):
                return "Hook couldn't send the answers." + (details.first.map { " " + UserFacingError.text($0) } ?? "")
            default:
                break
            }
        }
        return "Couldn't send the answers. \(UserFacingError.text(error))"
    }
}
