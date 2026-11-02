import Foundation

/// Where an ask stands with this Mac's review of its corrections.
public enum ReviewState: Equatable, Sendable {
    /// No revisions: an older Pond, This Mac mode, or an ask from before them.
    case legacy
    /// Rev 1, or the revision the owner accepted on this Mac is the current one.
    case current(RevisionStamp)
    /// A correction the owner hasn't accepted here. `shown` is the accepted (else last seen)
    /// revision; `baseline` its rev, nil when this Mac never showed the ask as current (the
    /// review then shows the full content, not a diff).
    case pending(shown: RevisionStamp?, current: RevisionStamp, baseline: Int?)
    /// The history failed its checks, or went back on what this Mac pinned.
    case historyChanged(HistoryProblem)

    /// No copy, link, file, Done, answer, reply or tick; Skip still works.
    public var isLocked: Bool {
        switch self {
        case .legacy, .current: return false
        case .pending, .historyChanged: return true
        }
    }

    /// What the review entry point offers, from the state alone (never from the Notice slot).
    public var action: ReviewAction? {
        switch self {
        case .legacy, .current: return nil
        case .pending(_, let current, _): return .review(current: current)
        case .historyChanged: return .trustHistory
        }
    }
}

/// The detail's review entry point: review a correction, or trust the Pond's history again.
public enum ReviewAction: Equatable, Sendable {
    case review(current: RevisionStamp)
    case trustHistory
}

public enum ReviewGate {
    /// - no history → legacy, unless the record pinned a rev above 1 (a stub, or a Pond that
    ///   lost its revisions) → historyChanged;
    /// - a Pond below 1.1.0 while the record pinned a rev above 1 → historyChanged;
    /// - a failed history or a pin violation → historyChanged;
    /// - current rev 1, or accepted == current → current;
    /// - otherwise pending, shown = accepted ?? seen (only a stamp the history still holds).
    ///
    /// Only pins above rev 1 count for a missing history: every ask is pinned at rev 1, and an
    /// ask that was never corrected has nothing an older Pond could hide.
    public static func resolve(record: ReviewRecord?, history: Result<VerifiedHistory, HistoryProblem>?,
                               pond: PondVersion?) -> ReviewState {
        let corrected = (record?.highestPin ?? 0) > 1
        if corrected, let pond, pond.effective < MailboxFeature.corrections.minimumPond {
            return .historyChanged(.missing)
        }
        guard let history else { return corrected ? .historyChanged(.missing) : .legacy }
        let verified: VerifiedHistory
        switch history {
        case .failure(let problem): return .historyChanged(problem)
        case .success(let value): verified = value
        }
        if let problem = RevisionCheck.checkPins(verified, pins: record?.pins ?? [:]) { return .historyChanged(problem) }
        let current = verified.current
        if current.rev == 1 || record?.accepted == current { return .current(current) }
        let shown = [record?.accepted, record?.seen].compactMap { $0 }.first { stamp in
            verified.stamps[stamp.rev] == stamp && stamp.rev < current.rev
        }
        return .pending(shown: shown, current: current, baseline: shown?.rev)
    }

    /// The revision the card and the detail render: the current one when current; when
    /// pending, `shown`, else rev 1 (locked, so nothing in it can be copied or opened). nil
    /// for legacy and historyChanged, and when the history lacks that body (a list item before
    /// its detail arrives).
    public static func renderedStamp(_ state: ReviewState, history: VerifiedHistory?) -> RevisionStamp? {
        guard let history else { return nil }
        switch state {
        case .legacy, .historyChanged:
            return nil
        case .current(let stamp):
            return history.body(stamp) == nil ? nil : stamp
        case .pending(let shown, _, _):
            if let shown, history.body(shown) != nil { return shown }
            if let first = history.stamps[1], history.bodies[1] != nil { return first }
            return nil
        }
    }

    public static func renderedBody(_ state: ReviewState, history: VerifiedHistory?) -> Instructable? {
        renderedStamp(state, history: history).flatMap { history?.body($0) }
    }
}
