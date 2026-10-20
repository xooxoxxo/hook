import Foundation

/// A choice reply travels as "choice: X" (unchanged from 0.5) and shows as "You chose: X".
public enum ReplyText {
    public static let prefix = "choice: "

    public static func wire(choice: String) -> String { prefix + choice }

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
            event.text.map { ReplyLine(id: event.seq, text: display($0), time: ClockText.time(event.at, locale: locale, timeZone: timeZone)) }
        }
    }

    private static func ownerReplies(_ events: [Event]) -> [Event] {
        events.filter { $0.kind == "reply" && $0.actor == "owner" }
    }

    private static func sentIndices(_ events: [Event], _ choices: [String]) -> [Int] {
        ownerReplies(events).compactMap { event in
            event.text.flatMap(choice(from:)).flatMap { choices.firstIndex(of: $0) }
        }
    }
}
