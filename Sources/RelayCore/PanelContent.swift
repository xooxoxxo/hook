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
    /// A phone write whose outcome cannot safely offer replay.
    case deliveryFailed(reason: String)
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
    /// The Pond is below the range this Hook needs (`PondVersion.display`, `PondCompat.required`):
    /// these features won't work until it is updated.
    case pondOlder(current: String, required: String, missing: [MailboxFeature])
    /// The Pond is on a newer major than this Hook's range.
    case hookOlder(pond: String)
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
    /// The Keychain refused the review seal key, or the item isn't the one Hook marked (or
    /// `reviews.json` is gone): corrected asks stay locked until the owner resets the records.
    case reviewRecordsUnreadable
    /// A Done held for Undo was dropped: the ask was corrected meanwhile.
    case doneHeldBack(id: String, title: String)
    /// The owner accepted a correction here, but the Pond didn't take it yet; Hook sends it
    /// again before Done or answers.
    case acceptFailed(id: String, title: String, reason: String)
    /// What a crash report send did ("Sent to your Pond.", "Comment copied. Paste it on the issue.").
    case crashReport(message: String)
    /// Harnesses found while "Set up new agents automatically" is off (`IntegrationNotice`).
    case newAgents(ids: [String], names: [String])
    /// The Pond refused the owner's Done with 409 requirements_unmet (Pond 1.3.0). It names no
    /// item (pick 1); Show opens the ask, whose marks say what's left.
    case doneRefused(id: String, title: String)

    /// The open ask this Notice is about, when it belongs to that ask's detail: it goes when
    /// the owner leaves the ask and never shows on the queue.
    public var detailAskID: String? {
        switch self {
        case .sessionClosed(let id), .corrected(let id, _), .historyChanged(let id), .doneHeldBack(let id, _): return id
        default: return nil
        }
    }

    /// A Notice that only reports something and asks nothing of the owner: it goes on its own
    /// after `DS.Motion.noticeHold`, and when the owner opens an ask.
    public var isCompact: Bool {
        if case .noLongerOpen = self { return true }
        return false
    }

    public var isTransient: Bool {
        switch self {
        case .noLongerOpen, .settingsReloaded, .mailboxUpToDate, .crashReport: return true
        default: return false
        }
    }

    public var showsOnQueue: Bool { detailAskID == nil }

    public var kind: NoticeKind {
        switch self {
        case .deliveryFailed, .actionFailed, .reopenFailed, .storeFailed, .queueMoved, .resumeFailed, .pondOlder,
             .mailboxUpdateFailed, .mailboxUpdateCommandInvalid, .ownerKeyRefused, .historyChanged, .acceptFailed,
             .reviewRecordsChanged, .reviewRecordsUnreadable: return .error
        case .settingsReloaded, .sessionClosed, .noLongerOpen, .offlineCached, .updating, .hookOlder,
             .mailboxUpToDate, .corrected, .doneHeldBack, .crashReport, .newAgents, .doneRefused: return .info
        }
    }

    public var text: String {
        switch self {
        case .deliveryFailed(let reason): return UserFacingError.text(reason)
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
        case let .pondOlder(current, required, _):
            return "Your Pond (\(Sanitize.revealLine(current))) is older than this Hook needs "
                + "(\(Sanitize.revealLine(required)))."
        case .hookOlder(let pond):
            return "Hook is older than your Pond (\(Sanitize.revealLine(pond))). Update Hook to catch up."
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
                + "Allow Hook when macOS asks, or reset the review records."
        case .doneHeldBack(_, let title):
            return "Done was held back: “\(Sanitize.revealLine(title))” was corrected."
        case .doneRefused(_, let title):
            return "“\(Sanitize.revealLine(title))” isn't finished yet: the Pond still waits for a marked item. "
                + "Finish it, or Skip."
        case .crashReport(let message):
            return message
        case .newAgents(_, let names):
            return IntegrationNotice.text(names: names.map(Sanitize.revealLine))
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
        case .pondOlder: return "Update Pond…"
        case .hookOlder: return "Check for Updates"
        case .corrected: return "Review Changes"
        case .historyChanged: return "Trust the Pond's History Again…"
        case .newAgents: return "Open Settings"
        case .doneRefused: return "Show"
        case .reviewRecordsUnreadable: return "Reset Review Records…"
        case .deliveryFailed, .storeFailed, .settingsReloaded, .updating, .resumeFailed, .mailboxUpToDate, .mailboxUpdateFailed,
             .mailboxUpdateCommandInvalid, .ownerKeyRefused, .reviewRecordsChanged,
             .doneHeldBack, .acceptFailed, .crashReport:
            return nil
        }
    }

    /// A second button before the first, when the Notice has one.
    public var secondaryActionTitle: String? {
        if case .pondOlder = self { return "How to update" }
        return nil
    }

    /// The text behind the Notice's "?", when it has one.
    public var help: String? {
        if case .pondOlder(_, _, let missing) = self {
            let features = missing.isEmpty ? "" : "Until it is updated, \(MailboxProtocol.featureList(missing)) won't work. "
            return features + "Hook checks your Pond's version when it connects and every 30 minutes. "
                + "Update Pond… runs the update command from Settings › Queue in your terminal, "
                + "or opens the update guide when none is set."
        }
        if case .reviewRecordsUnreadable = self {
            return "Hook seals what you reviewed in reviews.json, under a key in the Keychain it made itself. "
                + "When macOS asks for your password, Allow lets Hook read the key again. If reviews.json was "
                + "deleted, or the key isn't the one Hook made, Hook trusts neither. Reset Review Records… asks "
                + "for Touch ID and makes a new key: every corrected ask needs a review again, and each owner "
                + "key has to be set up again in Settings › Queue."
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
