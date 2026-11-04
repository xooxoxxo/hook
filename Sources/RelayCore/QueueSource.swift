import Foundation

public enum Verdict: String, Sendable {
    case done
    case declined
}

/// One queue the app shows: the mailbox service, or the local queue.
public protocol QueueSource: Sendable {
    /// Every open ask, whatever its age, newest first.
    func list() async throws -> [WireItem]
    func get(_ id: String) async throws -> AskDetail
    /// `instructable` is the raw JSON object's bytes; the source validates it.
    func post(project: String, instructable: Data) async throws -> PostResult
    /// The app always acts as the owner.
    func resolve(_ id: String, verdict: Verdict, note: String?) async throws -> WireItem
    func reply(_ id: String, text: String) async throws -> WireItem
    /// The owner's answers to step questions, sent as one batch: each entry is
    /// `{"step": "3.2", "picked": [...]}` or `{"step": "4", "text": "..."}` (see
    /// `Answers.entry`). The ask stays open. A closed ask throws `.askClosed`; answers
    /// that don't fit the questions throw `.rejected(400, "invalid answers", details)`.
    func answer(_ id: String, answers: [JSONValue]) async throws -> WireItem
    /// The app always acts as the owner. Reopening an open ask returns it unchanged.
    func reopen(_ id: String) async throws -> WireItem
    /// Asks closed (done or dismissed) whose completion time is within `interval` of now, newest first.
    func recentlyClosed(within interval: TimeInterval) async throws -> [WireItem]
    /// nil: the Store polls every pollSeconds. Otherwise each call returns a NEW
    /// stream that yields after every committed change, until the caller cancels it.
    func changes() async -> AsyncStream<Void>?

    // Pond 1.1.0. The defaults below are what a source without corrections does (This Mac
    // mode): the stamped acts forward to the plain ones, the rest throw 501 "not supported".

    /// Done or Skip bound to the revision the owner saw; a stale one throws `.corrected`.
    func resolve(_ id: String, verdict: Verdict, note: String?, stamp: RevisionStamp?) async throws -> WireItem
    /// Answers bound to the revision the owner saw; a stale one throws `.corrected`.
    func answer(_ id: String, answers: [JSONValue], stamp: RevisionStamp?) async throws -> WireItem
    /// The owner accepted this revision of a corrected ask.
    func accept(_ id: String, stamp: RevisionStamp) async throws -> WireItem
    /// A problem with one step (by id), sent to the posting session as quoted text.
    func problem(_ id: String, stepID: String, stamp: RevisionStamp, note: String) async throws -> WireItem
    func ownerStatus() async throws -> OwnerStatus
    func enroll(keyHash: String, label: String) async throws -> Enrollment
    func enrollment(_ id: String) async throws -> Enrollment
    func requireOwnerKey(_ on: Bool) async throws -> OwnerKeyRequirement

    // Pond 1.2.0.

    /// A Hook crash report: owner-signed `POST /asks` with `kind: "bug"`, filed once per
    /// signature and never sent to Telegram. A repeat adds an occurrence.
    func postBug(project: String, instructable: Data, signature: String) async throws -> BugPostResult
    /// A message to the posting session: `POST /asks/{id}/reply` with `kind: "message"`,
    /// owner-signed when enrolled. It answers, closes and changes nothing.
    func message(_ id: String, text: String) async throws -> WireItem

    // Pond 1.3.0.

    /// This Mac's tick changes on an ask with requirements, as step ids: `POST /asks/{id}/progress`,
    /// bound to the revision shown. A delta, so two Macs' ticks merge (RD 13).
    func progress(_ id: String, tick: [String], untick: [String], stamp: RevisionStamp?) async throws -> WireItem
}

extension QueueSource {
    /// Done or Skip without a note.
    public func resolve(_ id: String, verdict: Verdict) async throws -> WireItem {
        try await resolve(id, verdict: verdict, note: nil)
    }

    public func resolve(_ id: String, verdict: Verdict, note: String?, stamp: RevisionStamp?) async throws -> WireItem {
        try await resolve(id, verdict: verdict, note: note)
    }

    public func answer(_ id: String, answers: [JSONValue], stamp: RevisionStamp?) async throws -> WireItem {
        try await answer(id, answers: answers)
    }

    public func accept(_ id: String, stamp: RevisionStamp) async throws -> WireItem { throw QueueError.notSupported }

    public func problem(_ id: String, stepID: String, stamp: RevisionStamp, note: String) async throws -> WireItem {
        throw QueueError.notSupported
    }

    public func ownerStatus() async throws -> OwnerStatus { throw QueueError.notSupported }

    public func enroll(keyHash: String, label: String) async throws -> Enrollment { throw QueueError.notSupported }

    public func enrollment(_ id: String) async throws -> Enrollment { throw QueueError.notSupported }

    public func requireOwnerKey(_ on: Bool) async throws -> OwnerKeyRequirement { throw QueueError.notSupported }

    public func postBug(project: String, instructable: Data, signature: String) async throws -> BugPostResult {
        throw QueueError.notSupported
    }

    public func message(_ id: String, text: String) async throws -> WireItem { throw QueueError.notSupported }

    public func progress(_ id: String, tick: [String], untick: [String], stamp: RevisionStamp?) async throws -> WireItem {
        throw QueueError.notSupported
    }
}

/// What a crash report sent to the Pond became.
public enum BugPostResult: Equatable, Sendable {
    /// A new report.
    case filed(id: String)
    /// An open report with the same signature (or, on a Pond before 1.2.0, the same title)
    /// gained this crash; `count` is how often it happened, when the Pond says.
    case occurrence(id: String, count: Int?)

    /// "Sent to your Pond." or "Added to the existing report (3 times)."
    public var text: String {
        switch self {
        case .filed: return "Sent to your Pond."
        case .occurrence(_, let count?): return "Added to the existing report (\(count) times)."
        case .occurrence: return "Added to the existing report."
        }
    }
}

/// `POST /asks` with `kind: "bug"` → `{item, deduped?, occurrences}`.
struct BugPostResponse: Decodable {
    let item: WireItem
    let deduped: Bool?
    let occurrences: Int?

    var result: BugPostResult {
        deduped == true ? .occurrence(id: item.id, count: occurrences) : .filed(id: item.id)
    }
}

/// `POST /asks` → `{item, deduped?, openUrl?}`.
public struct PostResult: Sendable, Decodable, Equatable {
    public let item: WireItem
    public let deduped: Bool
    public let openURL: String?

    enum CodingKeys: String, CodingKey {
        case item, deduped
        case openURL = "openUrl"
    }

    public init(item: WireItem, deduped: Bool, openURL: String?) {
        self.item = item
        self.deduped = deduped
        self.openURL = openURL
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        item = try c.decode(WireItem.self, forKey: .item)
        deduped = try c.decodeIfPresent(Bool.self, forKey: .deduped) ?? false
        openURL = try c.decodeIfPresent(String.self, forKey: .openURL)
    }
}

/// Every failure a source reports. Reasons never carry a token or ask contents.
public enum QueueError: Error, Sendable, Equatable, LocalizedError {
    case unreachable(String)
    case unauthorized
    case notFound
    case rejected(status: Int, error: String, details: [String])
    case storeFailed(String)
    /// Answers to a closed ask (mailbox 409): read-only until the owner reopens it.
    case askClosed
    /// The act named a revision that isn't the one in force (409 "ask was corrected"):
    /// `rev` and `hash` are the current revision, `acceptedRev` the one the owner accepted.
    case corrected(rev: Int, hash: String, acceptedRev: Int?)
    /// The Pond doesn't know this Mac's owner key, or it was revoked (403 "unknown owner key").
    case ownerKeyRefused
    /// The owner's Done while the ask still waits for something (Pond 1.3.0, 409
    /// "requirements_unmet"): `left` is what the Pond still waits for.
    case requirementsUnmet(left: [PondRequirement])

    /// What a source without a Pond 1.1.0 route answers.
    public static let notSupported = QueueError.rejected(status: 501, error: "not supported", details: [])

    public var errorDescription: String? {
        switch self {
        case .unreachable(let reason):
            return reason
        case .unauthorized:
            return "The Pond rejected the token (check the token file)"
        case .notFound:
            return "not found"
        case .rejected(_, let error, let details):
            return details.isEmpty ? error : error + ": " + details.joined(separator: ", ")
        case .storeFailed(let reason):
            return "Couldn't save the queue: \(reason)"
        case .askClosed:
            return "This ask is closed. Reopen it to change the answers."
        case .corrected:
            return "This ask was corrected. Review the change before acting on it."
        case .ownerKeyRefused:
            return "The Pond no longer accepts this Mac's owner key."
        case .requirementsUnmet:
            return "This ask isn't finished yet: the Pond still waits for a marked item."
        }
    }
}
