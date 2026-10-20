import Foundation

/// Welcome's two pages (§4.9). Pure: the view feeds it Start, the first list, the 10 s
/// timer and config changes.
public struct WelcomeFlow: Equatable, Sendable {
    public enum Page: Sendable { case source, ready }

    public static let firstListTimeout: TimeInterval = MailboxDraft.connectTimeout

    public var page: Page = .source
    /// Start was pressed for a mailbox and the first list hasn't answered yet.
    public var starting = false
    /// "Can't reach the mailbox: <reason>", under the fields.
    public var error: String?

    public init() {}

    public mutating func startTapped(isMailbox: Bool) {
        guard page == .source else { return }
        error = nil
        if isMailbox {
            starting = true
        } else {
            page = .ready
        }
    }

    public mutating func firstList(ok: Bool, reason: String?) {
        guard page == .source, starting else { return }
        starting = false
        if ok {
            page = .ready
        } else {
            error = "Can't reach the mailbox: " + (reason ?? MailboxDraft.noAnswer)
        }
    }

    public mutating func timedOut() {
        firstList(ok: false, reason: MailboxDraft.noAnswer)
    }

    /// install.sh wrote a working config while page 1 was open. During Start the save is
    /// Start's own, so the first list decides.
    public mutating func configResolved() {
        guard page == .source, !starting else { return }
        page = .ready
    }
}
