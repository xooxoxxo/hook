import Foundation

/// One step of an instructable. The JSON keys `do` and `where` are
/// Swift keywords, so they map to `action` and `place`. A step in `steps` may
/// hold `substeps` (1 to 10 steps without their own sub-steps); validation, not
/// the type, forbids nesting and sub-steps on verify.
public struct Step: Codable, Sendable, Equatable {
    public var action: String
    public var place: String?
    public var code: String?
    public var lang: String?
    public var expect: String?
    /// Longer instructions for the step, shown as wrapped prose.
    public var detail: String?
    public var url: String?
    public var substeps: [Step]?
    /// What the owner is asked at this step or sub-step (never on verify).
    public var question: Question?

    enum CodingKeys: String, CodingKey {
        case action = "do"
        case place = "where"
        case code, lang, expect, detail, url, substeps, question
    }

    public init(action: String, place: String? = nil, code: String? = nil, lang: String? = nil, expect: String? = nil,
                detail: String? = nil, url: String? = nil, substeps: [Step]? = nil, question: Question? = nil) {
        self.action = action; self.place = place; self.code = code; self.lang = lang; self.expect = expect
        self.detail = detail; self.url = url; self.substeps = substeps; self.question = question
    }
}

/// A step's question. No choices (nil or empty) asks for free text; `multi` allows
/// several picks. The validator holds the limits; decoding only needs the shape.
public struct Question: Codable, Sendable, Equatable {
    public var prompt: String
    public var choices: [String]?
    public var multi: Bool?

    public init(prompt: String, choices: [String]? = nil, multi: Bool? = nil) {
        self.prompt = prompt; self.choices = choices; self.multi = multi
    }

    /// The choices to pick from; empty for a free-text question.
    public var options: [String] { choices ?? [] }
    public var isFreeText: Bool { options.isEmpty }
    /// Several picks allowed (only with choices).
    public var allowsMany: Bool { multi == true && !isFreeText }
}

extension Step {
    /// As the synthesized decoder did, plus a lenient `substeps` and `question`: null,
    /// the wrong type or a malformed value becomes nil instead of failing the instructable.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        action = try c.decode(String.self, forKey: .action)
        place = try c.decodeIfPresent(String.self, forKey: .place)
        code = try c.decodeIfPresent(String.self, forKey: .code)
        lang = try c.decodeIfPresent(String.self, forKey: .lang)
        expect = try c.decodeIfPresent(String.self, forKey: .expect)
        detail = try c.decodeIfPresent(String.self, forKey: .detail)
        url = try c.decodeIfPresent(String.self, forKey: .url)
        substeps = (try? c.decodeIfPresent([Step].self, forKey: .substeps)) ?? nil
        question = (try? c.decodeIfPresent(Question.self, forKey: .question)) ?? nil
    }
}

public struct ReplySpec: Codable, Sendable, Equatable {
    public var prompt: String
    public var choices: [String]?

    public init(prompt: String, choices: [String]? = nil) { self.prompt = prompt; self.choices = choices }
}

public struct LinkRef: Codable, Sendable, Equatable {
    public var label: String
    public var url: String

    public init(label: String, url: String) { self.label = label; self.url = url }
}

public struct Origin: Codable, Sendable, Equatable {
    public var session: String?
    public var host: String?
    public var cwd: String?

    public init(session: String? = nil, host: String? = nil, cwd: String? = nil) {
        self.session = session; self.host = host; self.cwd = cwd
    }
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

    public init(v: Int? = nil, title: String, why: String? = nil, urgency: String? = nil, steps: [Step],
                verify: Step? = nil, reply: ReplySpec? = nil, links: [LinkRef]? = nil, from: Origin? = nil) {
        self.v = v; self.title = title; self.why = why; self.urgency = urgency; self.steps = steps
        self.verify = verify; self.reply = reply; self.links = links; self.from = from
    }
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

    public init(why: String? = nil, cmd: String? = nil, link: String? = nil, instructable: Instructable? = nil) {
        self.why = why; self.cmd = cmd; self.link = link; self.instructable = instructable
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

    public init(id: String, title: String, status: String, projectId: String? = nil, created: String, updated: String,
                payload: Payload, completedAt: String? = nil) {
        self.id = id; self.title = title; self.status = status; self.projectId = projectId
        self.created = created; self.updated = updated; self.payload = payload; self.completedAt = completedAt
    }

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

    public init(seq: Int, itemId: String, kind: String, actor: String, text: String? = nil, at: String) {
        self.seq = seq; self.itemId = itemId; self.kind = kind; self.actor = actor; self.text = text; self.at = at
    }

    /// The kinds an owner's action records: a reply, a step answer, a close, or a reopen.
    public static let ownerKinds: Set<String> = ["reply", "answer", "resolved", "declined", "reopened"]
    /// The kinds that change whether an ask is open: a close or a reopen.
    public static let statusKinds: Set<String> = ["resolved", "declined", "reopened"]

    public var isOwnerEvent: Bool { actor == "owner" && Self.ownerKinds.contains(kind) }
}

/// `GET /asks/{id}`.
public struct AskDetail: Codable, Sendable, Equatable {
    public var item: WireItem
    public var events: [Event]

    public init(item: WireItem, events: [Event]) { self.item = item; self.events = events }

    /// The owner's replies, oldest first.
    public var ownerReplies: [String] {
        events.filter { $0.kind == "reply" && $0.actor == "owner" }.compactMap(\.text)
    }

    /// Every owner event (reply, answer, resolved, declined, reopened), oldest first.
    public var ownerEvents: [Event] {
        events.filter(\.isOwnerEvent)
    }
}
