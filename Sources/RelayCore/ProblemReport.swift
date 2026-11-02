import Foundation

/// What a problem report did (`Store.reportProblem`).
public enum ReportResult: Equatable, Sendable {
    case sent
    /// No approved owner key on this Mac: nothing was sent (`/problems` always needs it).
    case notEnrolled
    /// The note or the request was refused; the text says why, for the popover.
    case refused(String)
}

/// Report a Problem (Pond 1.1.0): a one-line note about one step, sent to the posting session
/// as a quoted report, never as an instruction. Only from Hook.
public enum ProblemReport {
    /// The Pond's limit, in characters (Python `len`, so Unicode scalars).
    public static let limit = 300

    public static let menuTitle = "Report a Problem…"
    public static let help = "The session gets this as a quoted report about its step. "
        + "Don't paste secrets; the Pond refuses them."
    public static let notEnrolled = "Set up the owner key in Settings › Queue first."
    public static let reportedCaption = "Reported · waiting for a correction"
    public static let secretRefused = "The Pond refused the note: it looks like a secret."

    /// Line breaks become spaces (the note is one line), then the ends are trimmed.
    public static func clean(_ note: String) -> String {
        let breaks: Set<Unicode.Scalar> = ["\n", "\r", "\u{2028}", "\u{2029}", "\u{0B}", "\u{0C}", "\u{85}"]
        let joined = String(String.UnicodeScalarView(note.unicodeScalars.map { breaks.contains($0) ? " " : $0 }))
        return joined.trimmingCharacters(in: .whitespaces)
    }

    /// Send is on for 1 to 300 characters once cleaned.
    public static func canSend(_ note: String) -> Bool {
        (1...limit).contains(clean(note).unicodeScalars.count)
    }

    /// "12/300".
    public static func counter(_ note: String) -> String {
        "\(clean(note).unicodeScalars.count)/\(limit)"
    }

    /// The popover's line for a refused send.
    public static func refusal(_ error: any Error) -> String {
        switch error as? QueueError {
        case .rejected(400, "invalid problem", let details)?:
            if details.contains(where: { $0.hasSuffix("secret-like value") }) { return secretRefused }
            return "The Pond refused the note: " + details.map(Sanitize.revealLine).joined(separator: ", ") + "."
        case .rejected(409, "too many reports", _)?:
            return "This ask has had 20 reports already."
        case .rejected(409, "stale revision", _)?, .corrected?:
            return "The ask was corrected meanwhile. Review it, then report on the new version."
        case .rejected(403, "owner key required", _)?:
            return notEnrolled
        default:
            return UserFacingError.text(error)
        }
    }

    /// The paths of the rendered tree whose step has a problem report the step hasn't been
    /// corrected since: the report's step (by id) reads the same now as in the revision it was
    /// made on. Without that revision's body, a report on the rendered rev or later counts.
    public static func reported(events: [Event], history: VerifiedHistory?, rendered: Instructable?,
                                renderedRev: Int?) -> Set<String> {
        guard let rendered else { return [] }
        let paths = StepIdentity.paths(rendered)
        let now = Dictionary(StepIdentity.entries(rendered).compactMap { e in e.step.id.map { ($0, e.step) } }) { a, _ in a }
        var out: Set<String> = []
        for event in events where event.kind == "problem" && event.actor == "owner" {
            guard let text = event.text, let body = try? JSONValue.parse(Data(text.utf8)),
                  let id = body["id"]?.stringValue, let path = paths[id], let step = now[id] else { continue }
            let rev = event.rev ?? 1
            if let then = history?.bodies[rev].flatMap({ ins in StepIdentity.entries(ins).first { $0.step.id == id }?.step }) {
                if StepIdentity.contentHash(then, parentID: nil, kind: .step)
                    == StepIdentity.contentHash(step, parentID: nil, kind: .step) { out.insert(path) }
            } else if rev >= (renderedRev ?? 1) {
                out.insert(path)
            }
        }
        return out
    }
}
