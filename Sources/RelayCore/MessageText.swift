import Foundation

/// The Messages section's send: idle, sending, or refused with why.
public enum MessageBoxState: Equatable, Sendable {
    case idle, sending, failed(String)
}

/// Messages to the posting session (Pond 1.2.0, pick 4 A): a side note, like typing in the
/// session's chat. A message answers, closes and changes nothing; it is kept verbatim
/// (multi-line) and only the session that posted the ask hears it.
public enum MessageText {
    /// The Pond keeps at most this many messages on one ask.
    public static let maxMessages = 50

    public static let heading = "Messages"
    public static let help = "A side note to the session, like typing in its chat. It answers and closes nothing, "
        + "and can't be changed once sent. Only the session that posted the ask sees it. "
        + "Don't paste secrets; the Pond refuses them."
    public static let placeholder = "Message the session"
    /// The disclosure the field sits behind on an ask with a reply prompt.
    public static let disclosure = "Message the session"
    /// The queue row's menu item.
    public static let menuTitle = "Message Session…"
    public static let caption = "⌘Return to send"
    public static let secretRefused = "The Pond refused the message: it looks like a secret."
    public static let closed = "This ask is closed, so the session won't get messages any more."
    public static let tooMany = "This ask has had \(maxMessages) messages already."

    /// Sent as typed. Send is on for 1 to `limits.message` characters (Unicode scalars) with
    /// something besides blanks.
    public static func canSend(_ text: String, limits: TalkLimits) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && count(text) <= limits.message
    }

    /// What the counter counts: the text as typed, in Unicode scalars.
    public static func count(_ text: String) -> Int { text.unicodeScalars.count }

    /// The line under the field for a refused send. Field paths only, never the text.
    public static func refusal(_ error: any Error, limits: TalkLimits) -> String {
        switch error as? QueueError {
        case .rejected(400, "invalid message", let details)?:
            if details.contains(where: { $0.hasSuffix("secret-like value") }) { return secretRefused }
            if details.contains(where: { $0.hasSuffix("too long") }) {
                return "The Pond refused the message: it is over \(limits.message) characters."
            }
            return "The Pond refused the message: " + details.map(Sanitize.revealLine).joined(separator: ", ") + "."
        case .rejected(400, "missing text", _)?:
            return "Type a message first."
        case .rejected(400, "invalid kind", _)?, .rejected(501, _, _)?:
            return "This Pond doesn't take messages. Update it to 1.2.0 or later."
        case .rejected(409, "ask is closed", _)?, .askClosed?:
            return closed
        case .rejected(409, "too many messages", _)?:
            return tooMany
        default:
            return UserFacingError.text(error)
        }
    }

    /// The owner's messages, oldest first, each with its time.
    public static func lines(events: [Event], locale: Locale = .current, timeZone: TimeZone = .current) -> [ReplyLine] {
        events.filter { $0.kind == "message" && $0.actor == "owner" }.compactMap { event in
            event.text.map {
                ReplyLine(id: event.seq, text: $0, time: ClockText.time(event.at, locale: locale, timeZone: timeZone))
            }
        }
    }
}
