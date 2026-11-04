import Foundation

/// A choice reply travels as "choice: X" (unchanged from 0.5) and shows as "You chose: X".
/// Pond 1.4.0 adds the owner's words on a choice that takes them: "choice: X · words".
public enum ReplyText {
    public static let prefix = "choice: "
    /// The key of the reply's words among an ask's choice words (step paths are the others).
    public static let wordsKey = "reply"
    /// Between a choice and the owner's words: U+00B7 with a space on each side.
    public static let separator = " \u{00B7} "

    public static func wire(choice: String) -> String { prefix + choice }

    /// "choice: Mix · words", with the words trimmed; nil or blank words send "choice: Mix".
    public static func wire(choice: String, words: String?) -> String {
        let trimmed = words?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? wire(choice: choice) : prefix + choice + separator + trimmed
    }

    /// Which of `choices` a reply picked, and the words beside it: the prefix and a label exactly,
    /// or the prefix, a label, the separator and non-empty words. Labels are tried longest first,
    /// so "Mix it" wins over "Mix", and a label holding the separator still reads whole.
    /// Compared by code point, as the Pond compares strings.
    public static func parse(_ text: String, choices: [String]) -> (index: Int, words: String?)? {
        let scalars = Array(text.unicodeScalars)
        let head = Array(prefix.unicodeScalars), gap = Array(separator.unicodeScalars)
        guard scalars.starts(with: head) else { return nil }
        let rest = scalars.dropFirst(head.count)
        let order = choices.indices.sorted {
            let a = choices[$0].unicodeScalars.count, b = choices[$1].unicodeScalars.count
            return a != b ? a > b : $0 < $1
        }
        for index in order {
            let label = Array(choices[index].unicodeScalars)
            guard rest.starts(with: label) else { continue }
            let tail = rest.dropFirst(label.count)
            if tail.isEmpty { return (index, nil) }
            if tail.starts(with: gap), tail.count > gap.count {
                return (index, String(String.UnicodeScalarView(tail.dropFirst(gap.count))))
            }
        }
        return nil
    }

    /// The words sent with the latest choice reply; nil when it had none, or there is none.
    public static func latestSentWords(events: [Event], choices: [String]) -> String? {
        ownerReplies(events).compactMap { event in event.text.flatMap { parse($0, choices: choices) } }.last?.words
    }

    /// The words a choice reply carries now: those typed, else (untouched, nil) those sent last,
    /// trimmed; nil when blank or when the choice at `choice` takes no words.
    public static func words(typed: String?, choice: Int?, sentWords: String?, spec: ReplySpec?) -> String? {
        guard let choice, spec?.placeholder(at: choice) != nil else { return nil }
        return trimmed(typed ?? sentWords)
    }

    /// The words on the sent choice differ from those sent with it (no other pick pending: a
    /// different pick is unsent anyway, and carries the words with it).
    public static func hasNewWords(typed: String?, choice: Int?, sent: Int?, sentWords: String?,
                                   spec: ReplySpec?) -> Bool {
        guard let sent, choice == nil || choice == sent else { return false }
        return words(typed: typed, choice: sent, sentWords: sentWords, spec: spec) != trimmed(sentWords)
    }

    private static func trimmed(_ text: String?) -> String? {
        let value = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : value
    }

    public static func choice(from text: String) -> String? {
        text.hasPrefix(prefix) ? String(text.dropFirst(prefix.count)) : nil
    }

    /// The choice is revealed here; free text stays raw (RepliesList runs prose()).
    public static func display(_ text: String) -> String {
        choice(from: text).map { "You chose: " + Sanitize.revealLine($0) } ?? text
    }

    public static func sentChoices(events: [Event], choices: [String]) -> Set<Int> {
        Set(sentIndices(events, choices))
    }

    public static func latestSentChoice(events: [Event], choices: [String]) -> Int? {
        sentIndices(events, choices).last
    }

    public static func lines(events: [Event], locale: Locale = .current, timeZone: TimeZone = .current) -> [ReplyLine] {
        ownerReplies(events).compactMap { event in
            event.text.map {
                ReplyLine(id: event.seq, text: display($0), time: ClockText.time(event.at, locale: locale, timeZone: timeZone),
                          choice: choice(from: $0).map(Sanitize.revealLine))
            }
        }
    }

    private static func ownerReplies(_ events: [Event]) -> [Event] {
        events.filter { $0.kind == "reply" && $0.actor == "owner" }
    }

    /// Word replies count too: "choice: Yes · words" is a sent "Yes".
    private static func sentIndices(_ events: [Event], _ choices: [String]) -> [Int] {
        ownerReplies(events).compactMap { event in
            event.text.flatMap { parse($0, choices: choices)?.index }
        }
    }
}
