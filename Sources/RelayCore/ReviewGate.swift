import CryptoKit
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
    /// - a Pond below 1.1.0 while the record pinned a rev above 1 → historyChanged;
    /// - no history and no pins → legacy;
    /// - no history, a pin above rev 1 (a stub, or a Pond that lost its revisions) → historyChanged;
    /// - no history, pinned at rev 1 only: on a Pond at 1.1.0 or later → historyChanged (it
    ///   serves revisions, so one dropped is a swap); on an older Pond, or before the version
    ///   check, legacy only while the served payload is the rev 1 this Mac verified
    ///   (`firstBodyHash`), else historyChanged;
    /// - a failed history or a pin violation → historyChanged;
    /// - current rev 1, or accepted == current → current;
    /// - otherwise pending, shown = accepted ?? seen (only a stamp the history still holds).
    ///
    /// `served` is the payload as the Pond sent it; it is read only for a pinned ask served
    /// without its revision.
    public static func resolve(record: ReviewRecord?, history: Result<VerifiedHistory, HistoryProblem>?,
                               pond: PondVersion?, served: Instructable? = nil) -> ReviewState {
        let corrected = (record?.highestPin ?? 0) > 1
        let oldPond = pond.map { $0.effective < MailboxFeature.corrections.minimumPond }
        if corrected, oldPond == true { return .historyChanged(.missing) }
        guard let history else {
            guard let record, !record.pins.isEmpty else { return .legacy }
            if corrected || oldPond == false { return .historyChanged(.missing) }
            // Rolled back to an older Pond (or not yet checked): the rev 1 this Mac verified,
            // and nothing else, still reads as a legacy ask.
            guard let first = record.firstBodyHash, let served, bodyHash(served) == first else {
                return .historyChanged(.missing)
            }
            return .legacy
        }
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

    /// SHA-256 (hex) over the decoded body's sorted-keys JSON without step ids: what the owner
    /// sees, whether the Pond serves it as rev 1 or (from before revisions) as a plain payload.
    public static func bodyHash(_ ins: Instructable) -> String {
        var plain = ins
        plain.steps = plain.steps.map(withoutIDs)
        plain.verify = plain.verify.map(withoutIDs)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let json = (try? encoder.encode(plain)) ?? Data()
        return SHA256.hash(data: json).map { String(format: "%02x", $0) }.joined()
    }

    private static func withoutIDs(_ step: Step) -> Step {
        var out = step
        out.id = nil
        out.substeps = out.substeps?.map(withoutIDs)
        return out
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
