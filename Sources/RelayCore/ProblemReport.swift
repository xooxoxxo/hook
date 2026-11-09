import Foundation

/// What a problem report did (`Store.reportProblem`).
public enum ReportResult: Equatable, Sendable {
    case sent
    /// No approved owner key on this Mac: nothing was sent (`/problems` always needs it).
    case notEnrolled
    /// The note or the request was refused; the text says why, for the popover.
    case refused(String)
}

/// The inline report field's send: idle, sending, held until the owner key is approved, or refused.
public enum ReportBoxState: Equatable, Sendable {
    case idle, sending, held, failed(String)
}

/// Report a Problem (Pond 1.1.0): a note about one step, sent to the posting session as a
/// quoted report, never as an instruction. Only from Hook. Pond 1.4.0 takes 8000 characters
/// over several lines; an older one 300 on one line (`TalkLimits`).
public enum ProblemReport {
    /// Outside the numbered step ID format. Used only for reports.
    public static let verifyTarget = "@verify"

    public static let menuTitle = "Report a Problem…"
    public static let help = "The session gets this as a quoted report about its step. "
        + "Don't paste secrets; the Pond refuses them."
    public static let notEnrolled = "Set up the owner key in Settings › Queue first."
    public static let secretRefused = "The Pond refused the note: it looks like a secret."

    /// The link at the bottom right of an expanded step (0.14).
    public static let linkTitle = "Report"
    public static let buttonHelp = "Report a problem with this step to the session"
    /// A reported step shows only the icon: this is its tooltip, and the label is VoiceOver's.
    public static let reportedHelp = "Reported. Waiting for a correction."
    public static let reportedLabel = "Problem reported, waiting for a correction"
    /// The inline field's prompt.
    public static let placeholder = "What went wrong? Paste the error if there is one."
    /// Send without an approved owner key holds the note, opens Settings › Queue and starts the setup.
    public static let heldCaption = "Sends once the owner key is approved."

    /// "Problem with step 2", "Problem with step 3b", "Problem with Verify".
    public static func composerTitle(label: String) -> String {
        label == "Verify" ? "Problem with Verify" : "Problem with step " + label
    }

    /// A step a report can be about: it has an id, and code or a tick (a step that asks a
    /// required question has no tick; only its answer completes it).
    public static func actionable(_ node: DetailModel.Node) -> Bool {
        node.stepID != nil && (node.code != nil || !node.asks || node.isOptional)
    }

    /// The queue row's Report a Problem…: the first unticked actionable leaf, else the first
    /// actionable one; nil when the ask has none.
    public static func firstTarget(nodes: [DetailModel.Node], ticks: Set<String>) -> String? {
        let leaves = Flow.flattened(nodes).filter { $0.children.isEmpty && actionable($0) }
        return (leaves.first { !ticks.contains($0.path) } ?? leaves.first)?.path
    }

    /// Line breaks become spaces (the note is one line), then the ends are trimmed.
    public static func clean(_ note: String) -> String {
        let breaks: Set<Unicode.Scalar> = ["\n", "\r", "\u{2028}", "\u{2029}", "\u{0B}", "\u{0C}", "\u{85}"]
        let joined = String(String.UnicodeScalarView(note.unicodeScalars.map { breaks.contains($0) ? " " : $0 }))
        return joined.trimmingCharacters(in: .whitespaces)
    }

    /// The note as it is sent: on Pond 1.4.0 as typed with its ends trimmed, line breaks kept (a
    /// pasted traceback keeps its lines); before, `clean`ed to one line.
    public static func prepared(_ note: String, limits: TalkLimits) -> String {
        limits.multilineReports ? note.trimmingCharacters(in: .whitespacesAndNewlines) : clean(note)
    }

    /// What the counter counts: the note as it would be sent, in Unicode scalars.
    public static func count(_ note: String, limits: TalkLimits) -> Int {
        prepared(note, limits: limits).unicodeScalars.count
    }

    /// Send is on for 1 to `limits.report` characters as it would be sent.
    public static func canSend(_ note: String, limits: TalkLimits) -> Bool {
        (1...limits.report).contains(count(note, limits: limits))
    }

    /// The line for a refused send.
    public static func refusal(_ error: any Error, limits: TalkLimits, target: String? = nil) -> String {
        switch error as? QueueError {
        case .rejected(400, "invalid problem", let details)?:
            if details.contains(where: { $0.hasSuffix("secret-like value") }) { return secretRefused }
            if details.contains(where: { $0.hasSuffix("too long") }) {
                return "The Pond refused the note: it is over \(limits.report) characters."
            }
            if target == verifyTarget && details == ["step: unknown"] {
                return "This Pond couldn’t save a Verify report. Use Report on a numbered step."
            }
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
                  let id = body["id"]?.stringValue else { continue }
            let rev = event.rev ?? 1
            let target: (path: String, step: Step, kind: StepFingerprint.Kind)
            let previous: Step?
            if id == verifyTarget {
                guard let verify = rendered.verify else { continue }
                target = ("verify", verify, .verify)
                previous = history?.bodies[rev]?.verify
            } else {
                guard let path = paths[id], let step = now[id] else { continue }
                target = (path, step, .step)
                previous = history?.bodies[rev].flatMap { ins in StepIdentity.entries(ins).first { $0.step.id == id }?.step }
            }
            if let previous {
                if StepIdentity.contentHash(previous, parentID: nil, kind: target.kind)
                    == StepIdentity.contentHash(target.step, parentID: nil, kind: target.kind) { out.insert(target.path) }
            } else if rev >= (renderedRev ?? 1) {
                out.insert(target.path)
            }
        }
        return out
    }
}
