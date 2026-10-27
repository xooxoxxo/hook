import Foundation
import os

/// Local timestamps: UTC, whole seconds and the literal offset "+00:00",
/// never "Z", so Python 3.9's `fromisoformat` reads them. The formatters aren't
/// Sendable, so each is built once and used only under its lock.
public enum Timestamp {
    public static func string(_ date: Date) -> String {
        writer.withLock { $0.formatter.string(from: date) }
    }

    /// Accepts any "+HH:MM" offset and "Z". Nil for anything else.
    /// The queue parses the same stamps on every list and every render, so answers are
    /// kept (up to `parseCacheLimit`, then the cache starts over).
    public static func date(_ text: String) -> Date? {
        parser.withLock { state in
            if let known = state.cache[text] { return known }
            let parsed = state.formatter.date(from: text)
            if state.cache.count >= parseCacheLimit { state.cache.removeAll(keepingCapacity: true) }
            state.cache[text] = .some(parsed)
            return parsed
        }
    }

    static let parseCacheLimit = 2048

    private struct Parser: @unchecked Sendable {
        let formatter: ISO8601DateFormatter
        var cache: [String: Date?] = [:]
    }

    private struct Writer: @unchecked Sendable {
        let formatter: DateFormatter
    }

    private static let parser: OSAllocatedUnfairLock<Parser> = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return OSAllocatedUnfairLock(initialState: Parser(formatter: formatter))
    }()

    private static let writer = OSAllocatedUnfairLock(
        initialState: Writer(formatter: utcFormatter("yyyy-MM-dd'T'HH:mm:ss'+00:00'")))

    /// "20261011-093000", for `queue.json.corrupt-<stamp>`.
    static func fileStamp(_ date: Date) -> String {
        utcFormatter("yyyyMMdd-HHmmss").string(from: date)
    }

    private static func utcFormatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = format
        return formatter
    }
}

extension KeyedEncodingContainer {
    /// Writes `null` for nil instead of leaving the key out: every wire key is always present.
    fileprivate mutating func encodeNullable<T: Encodable>(_ value: T?, forKey key: Key) throws {
        if let value {
            try encode(value, forKey: key)
        } else {
            try encodeNil(forKey: key)
        }
    }
}

/// `item.payload` of a local ask. Mailbox-only payload keys are absent.
public struct LocalPayload: Codable, Sendable, Equatable {
    public var why: String?
    /// The dedupe key.
    public var key: String
    /// The cleaned instructable (urgency defaulted).
    public var instructable: JSONValue

    enum CodingKeys: String, CodingKey {
        case why, key, instructable
    }

    public init(why: String?, key: String, instructable: JSONValue) {
        self.why = why
        self.key = key
        self.instructable = instructable
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        why = try c.decodeIfPresent(String.self, forKey: .why)
        key = try c.decode(String.self, forKey: .key)
        instructable = try c.decodeIfPresent(JSONValue.self, forKey: .instructable) ?? .null
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeNullable(why, forKey: .why)
        try c.encode(key, forKey: .key)
        try c.encode(instructable, forKey: .instructable)
    }
}

/// A local ask with every wire key of a mailbox item, so
/// `LocalAPI` serves the same shape as the mailbox.
public struct LocalItem: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var source: String
    public var title: String
    public var status: String
    public var priority: Int
    public var pinned: Bool
    public var rolling: Bool
    public var payloadType: String
    public var payload: LocalPayload
    public var links: JSONValue
    public var created: String
    public var updated: String
    public var anchor: JSONValue
    public var recurrence: JSONValue
    public var snoozeUntil: String?
    public var projectId: String?
    public var lane: String
    public var completedAt: String?

    enum CodingKeys: String, CodingKey {
        case id, source, title, status, priority, pinned, rolling, payloadType, payload, links
        case created, updated, anchor, recurrence, snoozeUntil, projectId, lane, completedAt
    }

    /// The projection the UI and `QueueSource` use: an encoded `LocalItem` read as a
    /// `WireItem`. Only the instructable needs the JSON round trip; a malformed one
    /// becomes nil, exactly as `Payload`'s lenient decoding would make it.
    public var wireItem: WireItem {
        let instructable = (try? JSONEncoder().encode(payload.instructable))
            .flatMap { try? JSONDecoder().decode(Instructable.self, from: $0) }
        return WireItem(
            id: id, title: title, status: status, projectId: projectId,
            created: created, updated: updated,
            payload: Payload(why: payload.why, cmd: nil, link: nil, instructable: instructable),
            completedAt: completedAt)
    }

    /// A new open ask with the mailbox's item defaults for every other key.
    static func newAsk(id: String, project: String, title: String, payload: LocalPayload, at stamp: String) -> LocalItem {
        LocalItem(
            id: id, source: "relay-local", title: title, status: "open",
            priority: 1, pinned: false, rolling: false, payloadType: "relay.ask",
            payload: payload, links: .array([]), created: stamp, updated: stamp,
            anchor: .null, recurrence: .null, snoozeUntil: nil, projectId: project,
            lane: "local", completedAt: nil)
    }
}

extension LocalItem {
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        source = try c.decode(String.self, forKey: .source)
        title = try c.decode(String.self, forKey: .title)
        status = try c.decode(String.self, forKey: .status)
        priority = try c.decode(Int.self, forKey: .priority)
        pinned = try c.decode(Bool.self, forKey: .pinned)
        rolling = try c.decode(Bool.self, forKey: .rolling)
        payloadType = try c.decode(String.self, forKey: .payloadType)
        payload = try c.decode(LocalPayload.self, forKey: .payload)
        links = try c.decodeIfPresent(JSONValue.self, forKey: .links) ?? .array([])
        created = try c.decode(String.self, forKey: .created)
        updated = try c.decode(String.self, forKey: .updated)
        anchor = try c.decodeIfPresent(JSONValue.self, forKey: .anchor) ?? .null
        recurrence = try c.decodeIfPresent(JSONValue.self, forKey: .recurrence) ?? .null
        snoozeUntil = try c.decodeIfPresent(String.self, forKey: .snoozeUntil)
        projectId = try c.decodeIfPresent(String.self, forKey: .projectId)
        lane = try c.decode(String.self, forKey: .lane)
        completedAt = try c.decodeIfPresent(String.self, forKey: .completedAt)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(source, forKey: .source)
        try c.encode(title, forKey: .title)
        try c.encode(status, forKey: .status)
        try c.encode(priority, forKey: .priority)
        try c.encode(pinned, forKey: .pinned)
        try c.encode(rolling, forKey: .rolling)
        try c.encode(payloadType, forKey: .payloadType)
        try c.encode(payload, forKey: .payload)
        try c.encode(links, forKey: .links)
        try c.encode(created, forKey: .created)
        try c.encode(updated, forKey: .updated)
        try c.encode(anchor, forKey: .anchor)
        try c.encode(recurrence, forKey: .recurrence)
        try c.encodeNullable(snoozeUntil, forKey: .snoozeUntil)
        try c.encodeNullable(projectId, forKey: .projectId)
        try c.encode(lane, forKey: .lane)
        try c.encodeNullable(completedAt, forKey: .completedAt)
    }
}

/// One entry of the append-only event log, as `GET /events` serves it.
public struct LocalEvent: Codable, Sendable, Equatable {
    public var seq: Int
    public var itemId: String
    public var kind: String
    public var actor: String
    public var text: String?
    public var at: String

    enum CodingKeys: String, CodingKey {
        case seq, itemId, kind, actor, text, at
    }

    public var event: Event {
        Event(seq: seq, itemId: itemId, kind: kind, actor: actor, text: text, at: at)
    }
}

extension LocalEvent {
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        seq = try c.decode(Int.self, forKey: .seq)
        itemId = try c.decode(String.self, forKey: .itemId)
        kind = try c.decode(String.self, forKey: .kind)
        actor = try c.decode(String.self, forKey: .actor)
        text = try c.decodeIfPresent(String.self, forKey: .text)
        at = try c.decode(String.self, forKey: .at)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(seq, forKey: .seq)
        try c.encode(itemId, forKey: .itemId)
        try c.encode(kind, forKey: .kind)
        try c.encode(actor, forKey: .actor)
        try c.encodeNullable(text, forKey: .text)
        try c.encode(at, forKey: .at)
    }
}

/// The whole of `queue.json`.
struct QueueState: Codable, Sendable, Equatable {
    var version: Int
    /// 16 random hex characters, new with every new queue file.
    var epoch: String
    /// The last event number used; never reused within an epoch.
    var seq: Int
    var items: [LocalItem]
    var events: [LocalEvent]

    static func empty() -> QueueState {
        let epoch = String(format: "%016llx", UInt64.random(in: UInt64.min...UInt64.max))
        return QueueState(version: 1, epoch: epoch, seq: 0, items: [], events: [])
    }
}

public enum LocalQueueError: Error, Sendable, Equatable {
    case locked
    case missingFields
    case invalidInstructable([String])
    case invalidProject([String])
    case queueFull
    case notFound
    case invalidNote([String])
    case missingText
    case textTooLong
    /// Answers to an ask that isn't open.
    case askClosed
    case invalidAnswers([String])
    case storeFailed(String)
}

public enum QueueLoadOutcome: Sendable, Equatable {
    case fresh
    case loaded
    /// `movedTo` is the full path of the unreadable file, now `queue.json.corrupt-<stamp>`.
    case recovered(movedTo: String)
}
