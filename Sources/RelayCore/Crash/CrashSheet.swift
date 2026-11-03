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

    public init(summary: CrashSummary, target: CrashTarget, pondOffered: Bool, preview: String,
                send: CrashSendState = .idle) {
        self.summary = summary
        self.target = target.effective(pondOffered: pondOffered)
        self.pondOffered = pondOffered
        self.preview = preview
        self.send = send
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
        switch target {
        case .pond: return "Send to Pond"
        case .github: return "Open Issue on GitHub…"
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
