import Foundation

/// A send in the crash sheet: idle, on its way, or refused with a reason to show.
public enum CrashSendState: Equatable, Sendable {
    case idle
    case sending
    case failed(String)
}

/// What the send sheet shows: where the report goes, exactly what is sent, and the send.
public struct CrashSheetModel: Equatable, Sendable {
    public var summary: CrashSummary
    public var target: CrashTarget
    /// My Pond is offered (a Pond plus an approved owner key).
    public var pondOffered: Bool
    /// Exactly what Send delivers: the summary and the last 40 log lines, redacted.
    public var preview: String
    public var send: CrashSendState
    /// GitHub's answer for the signature; nil while the search runs (or before GitHub is picked).
    public var match: IssueMatch?

    public init(summary: CrashSummary, target: CrashTarget, pondOffered: Bool, preview: String,
                send: CrashSendState = .idle, match: IssueMatch? = nil) {
        self.summary = summary
        self.target = target.effective(pondOffered: pondOffered)
        self.pondOffered = pondOffered
        self.preview = preview
        self.send = send
        self.match = match
    }

    /// GitHub, still searching for the signature: the primary button waits.
    public var checking: Bool { target == .github && match == nil }

    /// The closed issue a new one names ("Possibly the same as #N").
    public var sameAs: Int? {
        if case .closedOther(let number)? = match { return number }
        return nil
    }

    /// The new issue's title, body and link (log lines trimmed to fit the link).
    public var newIssue: (title: String, body: String, url: URL, trimmed: Bool) {
        let title = BugAsk.title(summary)
        let body = GitHubIssues.issueBody(preview, sameAs: sameAs)
        let made = GitHubIssues.newIssueURL(title: title, body: body)
        return (title, body, made.url, made.trimmed)
    }

    /// The GitHub callout: what the search found, or that it couldn't run.
    public var matchText: String? {
        guard target == .github else { return nil }
        switch match {
        case nil: return "Checking GitHub for this crash…"
        case .none?: return "No issue has this crash yet. GitHub opens a new one for you to review and submit."
        case .open(let number, _, _)?:
            return "An issue like this is open: #\(number). Add to #\(number)… opens it and copies a comment for you to paste."
        case .closedFixed(_, let version)?: return "Fixed in \(version). Update Hook."
        case .closedOther(let number)?:
            return "A closed issue, #\(number), has this crash. The new issue says it's possibly the same."
        case .unavailable?: return "Hook couldn't check GitHub for an existing issue. Check by hand, or open a new one."
        }
    }

    /// Opening the new issue also copies the full report: it didn't fit the link.
    public var trimNote: String? {
        guard opensNewIssue, newIssue.trimmed else { return nil }
        return "The report is too long for the link, so the full report also goes to the clipboard."
    }

    /// The primary button opens a new issue (no match, a closed one that isn't a fix, or no answer).
    public var opensNewIssue: Bool {
        guard target == .github else { return false }
        switch match {
        case .none?, .closedOther?, .unavailable?: return true
        case nil, .open?, .closedFixed?: return false
        }
    }

    /// Unavailable: "Check for an Existing Issue" in the callout, "Open New Issue" the primary.
    public var secondaryTitle: String? {
        target == .github && match == .unavailable ? "Check for an Existing Issue" : nil
    }

    /// The segmented control's choices, My Pond first.
    public var targets: [CrashTarget] { pondOffered ? [.pond, .github] : [.github] }

    public var sending: Bool { send == .sending }

    /// "Redacted · 1,412 characters".
    public var countText: String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "en_US")
        let n = formatter.string(from: NSNumber(value: preview.count)) ?? String(preview.count)
        return "Redacted · \(n) characters"
    }

    /// The primary button: "Send to Pond", or GitHub's "Open Issue on GitHub…".
    public var primaryTitle: String {
        switch (target, match) {
        case (.pond, _): return "Send to Pond"
        case (.github, .open(let number, _, _)?): return "Add to #\(number)…"
        case (.github, .closedFixed?): return "Update Hook"
        case (.github, .unavailable?): return "Open New Issue"
        case (.github, _): return "Open Issue on GitHub…"
        }
    }

    public static func targetName(_ target: CrashTarget) -> String {
        target == .pond ? "My Pond" : "GitHub"
    }

    public static let title = "Send a Crash Report"
    /// The "?" beside "What's sent".
    public static let reportHelp = "Only these fields are sent: the Hook and macOS versions, the CPU type, the "
        + "exception, Hook's own frames and the last 40 lines of the activity log. Ask titles, steps, replies and "
        + "tokens are never recorded. Your home folder shows as ~, your user name as <user>, hosts and addresses as "
        + "<host>, and anything token-like as <redacted>. The crash file itself is never attached."
}
