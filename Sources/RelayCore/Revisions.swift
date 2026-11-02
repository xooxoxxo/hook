import CryptoKit
import Foundation

/// A revision's hash (Pond 1.1.0): lowercase hex SHA-256 of
/// `"hook-rev-v1" US rev US prev US at US reason US body`, US = U+001F, over UTF-8. `body` is
/// the string as served: Hook hashes it and never re-encodes the JSON.
public enum RevisionHash {
    public static func make(rev: Int, prev: String, at: String, reason: String, body: String) -> String {
        let separator = "\u{1F}"
        let input = ["hook-rev-v1", String(rev), prev, at, reason, body].joined(separator: separator)
        return SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

public enum RevisionBodyError: Error, Equatable, Sendable {
    /// An object names the same key twice, at any depth (escapes decoded before comparing).
    case duplicateKey
    /// Not JSON, a lone surrogate, not an object, or not an instructable.
    case invalid
}

/// A revision's body, read strictly, so Hook and the Pond never read different text from
/// the same bytes.
public enum RevisionBody {
    /// `JSONValue.parse` (refuses broken JSON and lone surrogates), then the duplicate-key
    /// check over the same bytes, then the lenient `Instructable` decoder.
    public static func parse(_ body: String) throws -> Instructable {
        let data = Data(body.utf8)
        guard case .object? = try? JSONValue.parse(data) else { throw RevisionBodyError.invalid }
        guard let ordered = try? OrderedJSON.parse(data) else { throw RevisionBodyError.invalid }
        if OrderedJSON.hasDuplicateKeys(ordered) { throw RevisionBodyError.duplicateKey }
        guard let ins = try? JSONDecoder().decode(Instructable.self, from: data) else { throw RevisionBodyError.invalid }
        return ins
    }
}

/// Why an ask's history can't be trusted. Each raises the history Notice, and acting stays off.
public enum HistoryProblem: Error, Equatable, Sendable {
    /// That rev's hash isn't the hash of its served fields.
    case badHash(Int)
    /// That rev's `prev` isn't the previous rev's hash.
    case badChain(Int)
    /// That rev's body has duplicate keys or doesn't read as an instructable.
    case unreadable(Int)
    /// A rev this Mac pinned is gone or now has another hash.
    case rolledBack
    /// Revisions are missing: a gap, none served, or the item names one the history lacks.
    case missing
}

/// The revisions whose hashes checked out, by rev. From a fetched detail it holds every rev
/// (`isComplete`); from a list item only the current one.
public struct VerifiedHistory: Equatable, Sendable {
    public var bodies: [Int: Instructable]
    public var stamps: [Int: RevisionStamp]
    public var current: RevisionStamp
    /// The revision the Pond treats as in force (accepted by the owner); 1 when it names none.
    public var acceptedOnPond: Int
    /// Each rev's reason; rev 1's is "".
    public var reasons: [Int: String]
    /// Each rev's `at`, as served.
    public var times: [Int: String]

    public init(bodies: [Int: Instructable], stamps: [Int: RevisionStamp], current: RevisionStamp, acceptedOnPond: Int,
                reasons: [Int: String], times: [Int: String] = [:]) {
        self.bodies = bodies; self.stamps = stamps; self.current = current; self.acceptedOnPond = acceptedOnPond
        self.reasons = reasons; self.times = times
    }

    /// Every rev from 1 to the current one is here.
    public var isComplete: Bool { (1...current.rev).allSatisfy { bodies[$0] != nil } }

    /// The body of exactly this stamp: nil when the history lacks the rev or has another hash for it.
    public func body(_ stamp: RevisionStamp) -> Instructable? {
        stamps[stamp.rev] == stamp ? bodies[stamp.rev] : nil
    }

    public var currentBody: Instructable? { bodies[current.rev] }
}

/// Checks the revisions a Pond serves before anything renders from them.
public enum RevisionCheck {
    /// The whole history of a fetched ask: every rev 1…N present, each hash recomputed from
    /// its served fields, each `prev` the previous hash, every body strict, and the newest
    /// the item's `revision`. nil for an item without a revision (an older Pond, This Mac mode).
    public static func verify(_ detail: AskDetail) -> Result<VerifiedHistory, HistoryProblem>? {
        guard let served = detail.item.revision else { return nil }
        guard hashes(served.stamp, prev: served.prev, at: served.at, reason: served.reason, body: served.body) else {
            return .failure(.badHash(served.rev))
        }
        let revisions = detail.revisions.sorted { $0.rev < $1.rev }
        guard !revisions.isEmpty, revisions.map(\.rev) == Array(1...revisions.count) else { return .failure(.missing) }
        var bodies: [Int: Instructable] = [:], stamps: [Int: RevisionStamp] = [:]
        var reasons: [Int: String] = [:], times: [Int: String] = [:]
        var previous = ""
        for revision in revisions {
            guard hashes(revision.stamp, prev: revision.prev, at: revision.at, reason: revision.reason,
                         body: revision.body) else { return .failure(.badHash(revision.rev)) }
            guard revision.prev == previous else { return .failure(.badChain(revision.rev)) }
            guard let body = try? RevisionBody.parse(revision.body) else { return .failure(.unreadable(revision.rev)) }
            bodies[revision.rev] = body
            stamps[revision.rev] = revision.stamp
            reasons[revision.rev] = revision.reason
            times[revision.rev] = revision.at
            previous = revision.hash
        }
        let newest = revisions[revisions.count - 1].stamp
        guard newest.rev == served.rev else { return .failure(.missing) }
        guard newest == served.stamp else { return .failure(.badHash(served.rev)) }
        return .success(VerifiedHistory(bodies: bodies, stamps: stamps, current: newest,
                                        acceptedOnPond: accepted(served), reasons: reasons, times: times))
    }

    /// A list item's current revision on its own; nil for an item without one.
    public static func verify(listed item: WireItem) -> Result<VerifiedHistory, HistoryProblem>? {
        guard let served = item.revision else { return nil }
        guard served.rev >= 1,
              hashes(served.stamp, prev: served.prev, at: served.at, reason: served.reason, body: served.body) else {
            return .failure(.badHash(served.rev))
        }
        if served.rev == 1, !served.prev.isEmpty { return .failure(.badChain(1)) }
        guard let body = try? RevisionBody.parse(served.body) else { return .failure(.unreadable(served.rev)) }
        return .success(VerifiedHistory(bodies: [served.rev: body], stamps: [served.rev: served.stamp],
                                        current: served.stamp, acceptedOnPond: accepted(served),
                                        reasons: [served.rev: served.reason], times: [served.rev: served.at]))
    }

    /// `.rolledBack` when the current rev is below the highest pin, or a pinned rev the history
    /// holds has another hash. Pins of revs the history doesn't hold (a list item) are skipped.
    public static func checkPins(_ history: VerifiedHistory, pins: [Int: String]) -> HistoryProblem? {
        if let highest = pins.keys.max(), history.current.rev < highest { return .rolledBack }
        for (rev, hash) in pins {
            if let stamp = history.stamps[rev], stamp.hash != hash { return .rolledBack }
        }
        return nil
    }

    /// The fetched history brought up to date by the list: a newer listed revision is added on
    /// top (the next fetch checks its chain), the same one keeps the fetched history, and a
    /// fetched failure stands until the next fetch. The list decides whether there is a
    /// revision at all, and an older listed rev goes as it is (the pins catch it).
    public static func merge(fetched: Result<VerifiedHistory, HistoryProblem>?,
                             listed: Result<VerifiedHistory, HistoryProblem>?) -> Result<VerifiedHistory, HistoryProblem>? {
        guard let listed else { return nil }
        guard let fetched else { return listed }
        guard case .success(var history) = fetched else { return fetched }
        guard case .success(let latest) = listed else { return listed }
        if latest.current == history.current { return fetched }
        guard latest.current.rev > history.current.rev else {
            return latest.current.rev == history.current.rev ? .failure(.badHash(latest.current.rev)) : listed
        }
        let rev = latest.current.rev
        history.bodies[rev] = latest.bodies[rev]
        history.stamps[rev] = latest.current
        history.reasons[rev] = latest.reasons[rev]
        history.times[rev] = latest.times[rev]
        history.current = latest.current
        history.acceptedOnPond = latest.acceptedOnPond
        return .success(history)
    }

    private static func hashes(_ stamp: RevisionStamp, prev: String, at: String, reason: String, body: String) -> Bool {
        RevisionHash.make(rev: stamp.rev, prev: prev, at: at, reason: reason, body: body) == stamp.hash
    }

    private static func accepted(_ served: ServedRevision) -> Int {
        min(max(served.acceptedRev ?? 1, 1), served.rev)
    }
}
