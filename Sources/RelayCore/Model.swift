import Foundation

/// One step of an instructable. The JSON keys `do` and `where` are
/// Swift keywords, so they map to `action` and `place`.
public struct Step: Codable, Sendable, Equatable {
    public var action: String
    public var place: String?
    public var code: String?
    public var lang: String?
    public var expect: String?
    /// Longer instructions for the step, shown as wrapped prose.
    public var detail: String?
    public var url: String?

    enum CodingKeys: String, CodingKey {
        case action = "do"
        case place = "where"
        case code, lang, expect, detail, url
    }
}

public struct ReplySpec: Codable, Sendable, Equatable {
    public var prompt: String
    public var choices: [String]?
}

public struct LinkRef: Codable, Sendable, Equatable {
    public var label: String
    public var url: String
}

public struct Origin: Codable, Sendable, Equatable {
    public var session: String?
    public var host: String?
    public var cwd: String?
}

/// An instructable (`"v": 1`). The mailbox service validates strictly; Relay only displays it, so
/// decoding here is lenient (no length checks, unknown urgency is kept as-is).
public struct Instructable: Codable, Sendable, Equatable {
    public var v: Int?
    public var title: String
    public var why: String?
    public var urgency: String?
    public var steps: [Step]
    public var verify: Step?
    public var reply: ReplySpec?
    public var links: [LinkRef]?
    public var from: Origin?
}

/// `item.payload` as the mailbox stores it. Legacy asks carry only why/cmd/link;
/// any other keys the mailbox keeps there are ignored.
public struct Payload: Codable, Sendable, Equatable {
    public var why: String?
    public var cmd: String?
    public var link: String?
    public var instructable: Instructable?

    enum CodingKeys: String, CodingKey {
        case why, cmd, link, instructable
    }
}

extension Payload {
    /// Lenient: a field of the wrong type, or a malformed instructable, becomes nil
    /// instead of failing the whole item.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        why = try? c.decodeIfPresent(String.self, forKey: .why)
        cmd = try? c.decodeIfPresent(String.self, forKey: .cmd)
        link = try? c.decodeIfPresent(String.self, forKey: .link)
        instructable = try? c.decodeIfPresent(Instructable.self, forKey: .instructable)
    }
}

/// The fields of the mailbox's item envelope that Relay uses.
public struct WireItem: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String
    /// "open", "done" or "dismissed".
    public var status: String
    public var projectId: String?
    public var created: String
    public var updated: String
    public var payload: Payload
    /// When the ask was last closed; nil while it is open.
    public var completedAt: String? = nil

    public var instructable: Instructable? { payload.instructable }

    /// "now", "today" or "whenever". Legacy asks count as "today".
    public var urgency: String { payload.instructable?.urgency ?? "today" }
}

public struct Event: Codable, Sendable, Equatable {
    public var seq: Int
    public var itemId: String
    public var kind: String
    public var actor: String
    public var text: String?
    public var at: String

    /// The kinds an owner's action records: an answer, a close, or a reopen.
    public static let ownerKinds: Set<String> = ["reply", "resolved", "declined", "reopened"]
    /// The kinds that change whether an ask is open: a close or a reopen.
    public static let statusKinds: Set<String> = ["resolved", "declined", "reopened"]

    public var isOwnerEvent: Bool { actor == "owner" && Self.ownerKinds.contains(kind) }
}

/// `GET /asks/{id}`.
public struct AskDetail: Codable, Sendable, Equatable {
    public var item: WireItem
    public var events: [Event]

    /// The owner's replies, oldest first.
    public var ownerReplies: [String] {
        events.filter { $0.kind == "reply" && $0.actor == "owner" }.compactMap(\.text)
    }

    /// Every owner event (reply, resolved, declined, reopened), oldest first.
    public var ownerEvents: [Event] {
        events.filter(\.isOwnerEvent)
    }
}
