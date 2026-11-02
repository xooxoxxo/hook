import Foundation

/// Which one of the panel's states fills the list area. Each state has one place and one text.
public enum PanelContent: Equatable, Sendable {
    case loading(stillTrying: Bool), notSetUp, offline(local: Bool, reason: String), empty, emptyFiltered(project: String), list

    /// "Nothing waiting" only after the source answered with an empty list.
    public static func resolve(sourceKey: String, loadedOnce: Bool, reachable: Bool, problem: String?, waitedTenSeconds: Bool,
                               filter: String?, shownOpen: Int, shownClosed: Int) -> PanelContent {
        if sourceKey == SourceKey.none { return .notSetUp }
        guard loadedOnce else {
            if !reachable, let problem {
                return .offline(local: sourceKey == SourceKey.local, reason: UserFacingError.text(problem))
            }
            return .loading(stillTrying: waitedTenSeconds)
        }
        if shownOpen == 0, shownClosed == 0 {
            return filter.map { .emptyFiltered(project: $0) } ?? .empty
        }
        return .list
    }
}

/// The one Notice the panel shows at a time. Texts are display-ready.
public enum PanelNotice: Equatable, Sendable {
    case actionFailed(verdict: Verdict, id: String, title: String, reason: String)
    case reopenFailed(id: String, title: String, reason: String)
    /// No caller yet: a reopen or reply that fails to save already shows its error in its own
    /// Notice or ReplyBox. A future poster passes the raw reason
    /// (`case QueueError.storeFailed(let reason)` → `.storeFailed(reason: reason)`), never
    /// `UserFacingError.text(error)`, which would double the "Couldn't save the queue" prefix.
    case storeFailed(reason: String)
    case queueMoved(path: String)
    case settingsReloaded
    case sessionClosed(id: String)
    case noLongerOpen(id: String, canShowClosed: Bool)
    case offlineCached(since: String)
    case updating(version: String, logPath: String)
    /// Resume Session couldn't open the terminal; the command was copied instead.
    case resumeFailed(reason: String)
    /// The mailbox's protocol level is below Hook's: these features won't work.
    case mailboxOlder(missing: [MailboxFeature])
    /// The mailbox speaks a level this Hook doesn't know.
    case mailboxNewer
    /// After Update Pond…: the Pond now fits the range Hook needs (`PondVersion.display`).
    case mailboxUpToDate(pond: String)
    /// Update Mailbox… couldn't open the terminal; the command was copied instead.
    case mailboxUpdateFailed(reason: String)
    /// Update Mailbox… wasn't started: the command in Settings can't be run (`RunTarget.problem`).
    case mailboxUpdateCommandInvalid(reason: String)
    /// An owner act got 403 "unknown owner key": this Mac's key was revoked or never approved.
    case ownerKeyRefused
    /// The open ask was corrected after the owner saw it; its review entry is `reviewAction`.
    case corrected(id: String, rev: Int)
    /// The open ask's history failed its checks or went back on what this Mac pinned.
    case historyChanged(id: String)
    /// A sealed review record failed its check and was dropped.
    case reviewRecordsChanged
    /// The Keychain refused the review seal key: corrected asks stay locked.
    case reviewRecordsUnreadable
    /// A Done held for Undo was dropped: the ask was corrected meanwhile.
    case doneHeldBack(id: String, title: String)
    /// The owner accepted a correction here, but the Pond didn't take it yet; Hook sends it
    /// again before Done or answers.
    case acceptFailed(id: String, title: String, reason: String)

    /// The open ask this Notice is about, when it belongs to that ask's detail: it goes when
    /// the owner leaves the ask and never shows on the queue.
    public var detailAskID: String? {
        switch self {
        case .sessionClosed(let id), .corrected(let id, _), .historyChanged(let id), .doneHeldBack(let id, _): return id
        default: return nil
        }
    }

    public var showsOnQueue: Bool { detailAskID == nil }

    public var kind: NoticeKind {
        switch self {
        case .actionFailed, .reopenFailed, .storeFailed, .queueMoved, .resumeFailed, .mailboxOlder,
             .mailboxUpdateFailed, .mailboxUpdateCommandInvalid, .ownerKeyRefused, .historyChanged, .acceptFailed,
             .reviewRecordsChanged, .reviewRecordsUnreadable: return .error
        case .settingsReloaded, .sessionClosed, .noLongerOpen, .offlineCached, .updating, .mailboxNewer,
             .mailboxUpToDate, .corrected, .doneHeldBack: return .info
        }
    }

    public var text: String {
        switch self {
        case let .actionFailed(verdict, _, title, reason):
            return "Couldn't send \(verdict == .done ? "Done" : "Skip") for “\(Sanitize.revealLine(title))”. \(UserFacingError.text(reason))"
        case let .reopenFailed(_, title, reason):
            return "Couldn't reopen “\(Sanitize.revealLine(title))”. \(UserFacingError.text(reason))"
        case .storeFailed(let reason):
            return "Couldn't save the queue. \(UserFacingError.text(reason))"
        case .queueMoved(let path):
            return "queue.json couldn't be read, so it was moved to \(Sanitize.revealLine(path)). A new queue has started."
        case .settingsReloaded:
            return "Settings changed, so the queue reloaded."
        case .sessionClosed:
            return "The session closed this ask."
        case .noLongerOpen:
            return "This ask is no longer open."
        case .offlineCached(let since):
            return "Offline · showing asks from \(since)"
        case .updating(let version, _):
            return "Updating to \(Sanitize.revealLine(version)). Hook restarts in about 2 minutes."
        case .resumeFailed(let reason):
            return "Couldn't open the terminal, so the resume command is on the clipboard. \(Sanitize.revealLine(reason))"
        case .mailboxOlder(let missing):
            let features = MailboxProtocol.featureList(missing)
            return "Your Pond is older than Hook: \(features) won't work until it is updated."
        case .mailboxNewer:
            return "Hook is older than your Pond. Update Hook to catch up."
        case .mailboxUpToDate(let pond):
            return "Your Pond is up to date (\(Sanitize.revealLine(pond)))."
        case .mailboxUpdateFailed(let reason):
            return "Couldn't open the terminal, so the update command is on the clipboard. \(Sanitize.revealLine(reason))"
        case .mailboxUpdateCommandInvalid(let reason):
            return "The Pond update command in Settings can't be run: \(Sanitize.revealLine(reason))."
        case .ownerKeyRefused:
            return "The Pond no longer accepts this Mac's owner key. Set it up again in Settings › Queue."
        case .corrected:
            return "Corrected after you saw it. Review before you copy anything."
        case .historyChanged:
            return "This ask's history changed on the Pond. Don't act on it: skip it, or trust the Pond's history "
                + "again after a restore."
        case .reviewRecordsChanged:
            return "Hook's review records were changed outside Hook, so corrected asks need a review again."
        case .reviewRecordsUnreadable:
            return "Hook couldn't read its review key from the Keychain, so corrected asks stay locked. "
                + "Allow Hook when macOS asks."
        case .doneHeldBack(_, let title):
            return "Done was held back: “\(Sanitize.revealLine(title))” was corrected."
        case let .acceptFailed(_, title, reason):
            return "The Pond didn't take your review of “\(Sanitize.revealLine(title))” yet: "
                + "\(UserFacingError.text(reason)) Hook sends it again before Done or answers."
        }
    }

    public var actionTitle: String? {
        switch self {
        case .actionFailed, .reopenFailed: return "Retry"
        case .queueMoved: return "Show in Finder"
        case .sessionClosed: return "Next Ask"
        case .noLongerOpen(_, let canShowClosed): return canShowClosed ? "Show Closed Ask" : nil
        case .offlineCached: return "Try Again"
        case .mailboxOlder: return "Update Pond…"
        case .mailboxNewer: return "Check for Updates"
        case .corrected: return "Review Changes"
        case .historyChanged: return "Trust the Pond's History Again…"
        case .storeFailed, .settingsReloaded, .updating, .resumeFailed, .mailboxUpToDate, .mailboxUpdateFailed,
             .mailboxUpdateCommandInvalid, .ownerKeyRefused, .reviewRecordsChanged, .reviewRecordsUnreadable,
             .doneHeldBack, .acceptFailed:
            return nil
        }
    }

    /// A second button before the first, when the Notice has one.
    public var secondaryActionTitle: String? {
        if case .mailboxOlder = self { return "How to update" }
        return nil
    }

    /// The text behind the Notice's "?", when it has one.
    public var help: String? {
        if case .mailboxOlder = self {
            return "Hook checks your Pond's protocol level when it connects and every 30 minutes. "
                + "Update Pond… runs the update command from Settings › Queue in your terminal, "
                + "or opens the update guide when none is set."
        }
        guard case .updating(_, let logPath) = self else { return nil }
        return "Hook rebuilds from your checkout, then quits and starts again. "
            + "If the update fails, the old Hook keeps running. The log says why: \(Sanitize.revealLine(logPath))"
    }
}

/// The Steps area while an ask's detail is fetched: "Loading steps…", then after
/// `timeout` (or a failed fetch) "Couldn't load this ask." with Try Again. The caller
/// owns the wait length, so the UI keeps it with its other timing tokens.
public enum DetailLoadState: Equatable, Sendable {
    case loaded, loading, timedOut

    public static func resolve(hasModel: Bool, requestedAt: Date?, now: Date, failed: Bool,
                               timeout: TimeInterval) -> DetailLoadState {
        if hasModel { return .loaded }
        if failed { return .timedOut }
        if let requestedAt, now.timeIntervalSince(requestedAt) >= timeout { return .timedOut }
        return .loading
    }
}
