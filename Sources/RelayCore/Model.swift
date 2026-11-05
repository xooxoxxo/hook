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
    /// Later steps wait until this one is done (never on verify).
    public var blocking: Bool?
    /// A caution shown with the step, multi-line (never on verify).
    public var warning: String?
    /// The owner may mark it done without doing it or answering its question (never
    /// on verify, never together with `blocking`).
    public var optional: Bool?
    /// An absolute local path ("/…" or "~/…") to a document the owner should read,
    /// usually Markdown (never on verify).
    public var file: String?
    /// Done stays off until this step is finished: ticked, answered, or (a parent) every
    /// sub-step that isn't optional (Pond 1.3.0; never on verify, never with `optional`).
    public var required: Bool?
    /// The step's stable id (Pond 1.1.0): "s1", "s3.1", or a session's own. Corrections keep
    /// it, so ticks and answers follow the step (never on verify).
    public var id: String?

    enum CodingKeys: String, CodingKey {
        case action = "do"
        case place = "where"
        case code, lang, expect, detail, url, substeps, question, blocking, warning, optional, file, required, id
    }

    public init(action: String, place: String? = nil, code: String? = nil, lang: String? = nil, expect: String? = nil,
                detail: String? = nil, url: String? = nil, substeps: [Step]? = nil, question: Question? = nil,
                blocking: Bool? = nil, warning: String? = nil, optional: Bool? = nil, file: String? = nil,
                required: Bool? = nil, id: String? = nil) {
        self.action = action; self.place = place; self.code = code; self.lang = lang; self.expect = expect
        self.detail = detail; self.url = url; self.substeps = substeps; self.question = question
        self.blocking = blocking; self.warning = warning; self.optional = optional; self.file = file
        self.required = required; self.id = id
    }
}

/// A step's question. No choices (nil or empty) asks for free text; `multi` allows
/// several picks. The validator holds the limits; decoding only needs the shape. A choice
/// may take the owner's words (Pond 1.4.0, `Choice.text`).
public struct Question: Codable, Sendable, Equatable {
    public var prompt: String
    public var choices: [Choice]?
    public var multi: Bool?

    public init(prompt: String, choices: [Choice]? = nil, multi: Bool? = nil) {
        self.prompt = prompt; self.choices = choices; self.multi = multi
    }

    /// The labels to pick from; empty for a free-text question.
    public var options: [String] { choices?.labels ?? [] }
    /// The words field's placeholder of the choice at `index`; nil for a plain choice or no choice there.
    public func placeholder(at index: Int) -> String? {
        guard let choices, choices.indices.contains(index) else { return nil }
        return choices[index].text
    }
    /// Some choice takes the owner's words.
    public var hasWords: Bool { choices?.contains(where: \.hasWords) ?? false }
    public var isFreeText: Bool { options.isEmpty }
    /// Several picks allowed (only with choices).
    public var allowsMany: Bool { multi == true && !isFreeText }
}

extension Step {
    /// As the synthesized decoder did, plus a lenient `substeps`, `question`, `blocking`,
    /// `warning`, `optional`, `file`, `required` and `id`: null,
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
        blocking = (try? c.decodeIfPresent(Bool.self, forKey: .blocking)) ?? nil
        warning = (try? c.decodeIfPresent(String.self, forKey: .warning)) ?? nil
        optional = (try? c.decodeIfPresent(Bool.self, forKey: .optional)) ?? nil
        file = (try? c.decodeIfPresent(String.self, forKey: .file)) ?? nil
        required = (try? c.decodeIfPresent(Bool.self, forKey: .required)) ?? nil
        id = (try? c.decodeIfPresent(String.self, forKey: .id)) ?? nil
    }
}

public struct ReplySpec: Codable, Sendable, Equatable {
    public var prompt: String
    public var choices: [Choice]?

    public init(prompt: String, choices: [Choice]? = nil) { self.prompt = prompt; self.choices = choices }

    /// The labels to pick from; empty for a free-text reply.
    public var options: [String] { choices?.labels ?? [] }
    /// The words field's placeholder of the choice at `index`; nil for a plain choice or no choice there.
    public func placeholder(at index: Int) -> String? {
        guard let choices, choices.indices.contains(index) else { return nil }
        return choices[index].text
    }
    /// Some choice takes the owner's words.
    public var hasWords: Bool { choices?.contains(where: \.hasWords) ?? false }
}

/// A link: a web `url`, or (protocol level 4) a `path` to a local document. The
/// validator requires exactly one; decoding is lenient, so either may be nil and a
/// malformed one is nil.
public struct LinkRef: Codable, Sendable, Equatable {
    public var label: String
    public var url: String?
    /// An absolute local path ("/…" or "~/…").
    public var path: String?

    public init(label: String, url: String? = nil, path: String? = nil) {
        self.label = label; self.url = url; self.path = path
    }

    /// The local document this link opens: `path` when there is no `url` (a link that
    /// says both stays a web link, as the validator never lets both through).
    public var file: String? { url == nil ? path : nil }

    enum CodingKeys: String, CodingKey {
        case label, url, path
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        label = try c.decode(String.self, forKey: .label)
        url = (try? c.decodeIfPresent(String.self, forKey: .url)) ?? nil
        path = (try? c.decodeIfPresent(String.self, forKey: .path)) ?? nil
    }
}

public struct Origin: Codable, Sendable, Equatable {
    public var session: String?
    public var host: String?
    public var cwd: String?

    public init(session: String? = nil, host: String? = nil, cwd: String? = nil) {
        self.session = session; self.host = host; self.cwd = cwd
    }
}

/// An instructable (`"v": 1`). The mailbox service validates strictly; Hook only displays it, so
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
    /// What must happen before the owner's Done (Pond 1.3.0): "steps", "reply", "message".
    /// Lenient: a non-list is nil, and only its strings are kept; an unknown value stays here
    /// raw and the model ignores it (`DoneRequirement`).
    public var done: [String]?
    /// A caution above all steps; independent of step ordering.
    public var warning: String?

    enum CodingKeys: String, CodingKey {
        case v, title, why, urgency, steps, verify, reply, links, from, done, warning
    }

    public init(v: Int? = nil, title: String, why: String? = nil, urgency: String? = nil, steps: [Step],
                verify: Step? = nil, reply: ReplySpec? = nil, links: [LinkRef]? = nil, from: Origin? = nil,
                done: [String]? = nil, warning: String? = nil) {
        self.v = v; self.title = title; self.why = why; self.urgency = urgency; self.steps = steps
        self.verify = verify; self.reply = reply; self.links = links; self.from = from; self.done = done; self.warning = warning
    }

    /// As the synthesized decoder did, plus a lenient `done`.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        v = try c.decodeIfPresent(Int.self, forKey: .v)
        title = try c.decode(String.self, forKey: .title)
        warning = (try? c.decodeIfPresent(String.self, forKey: .warning)) ?? nil
        why = try c.decodeIfPresent(String.self, forKey: .why)
        urgency = try c.decodeIfPresent(String.self, forKey: .urgency)
        steps = try c.decode([Step].self, forKey: .steps)
        verify = try c.decodeIfPresent(Step.self, forKey: .verify)
        reply = try c.decodeIfPresent(ReplySpec.self, forKey: .reply)
        links = try c.decodeIfPresent([LinkRef].self, forKey: .links)
        from = try c.decodeIfPresent(Origin.self, forKey: .from)
        if let raw = (try? c.decodeIfPresent(JSONValue.self, forKey: .done)) ?? nil, case .array(let values) = raw {
            done = values.compactMap(\.stringValue)
        } else {
            done = nil
        }
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

/// Which revision of an ask an owner act was made on (Pond 1.1.0).
public struct RevisionStamp: Codable, Sendable, Hashable {
    public var rev: Int
    public var hash: String

    public init(rev: Int, hash: String) { self.rev = rev; self.hash = hash }
}

/// One entry of an ask's revision history (`revisions` in `GET /asks/{id}`). `body` is the
/// canonical JSON string the hash covers: hash it as served, never re-encode it.
public struct Revision: Codable, Sendable, Equatable {
    public var rev: Int
    public var hash: String
    /// The previous revision's hash; "" for rev 1.
    public var prev: String
    public var at: String
    /// Why the session corrected the ask; "" for rev 1.
    public var reason: String
    public var body: String

    public init(rev: Int, hash: String, prev: String, at: String, reason: String, body: String) {
        self.rev = rev; self.hash = hash; self.prev = prev; self.at = at; self.reason = reason; self.body = body
    }

    public var stamp: RevisionStamp { RevisionStamp(rev: rev, hash: hash) }
}

/// An item's current revision (`item.revision`), served to a client that sends
/// `X-Hook-Protocol: 5`, with the revision the owner last accepted.
public struct ServedRevision: Codable, Sendable, Equatable {
    public var rev: Int
    public var hash: String
    public var prev: String
    public var at: String
    public var reason: String
    public var body: String
    /// The revision in force for Telegram, answers and Done; nil when the Pond names none.
    public var acceptedRev: Int?

    public init(rev: Int, hash: String, prev: String, at: String, reason: String, body: String,
                acceptedRev: Int? = nil) {
        self.rev = rev; self.hash = hash; self.prev = prev; self.at = at; self.reason = reason; self.body = body
        self.acceptedRev = acceptedRev
    }

    public var stamp: RevisionStamp { RevisionStamp(rev: rev, hash: hash) }
}

/// One requirement the Pond still waits for (Pond 1.3.0): `kind` "step" (with the step's
/// `id` and display `path`), "reply" or "message".
public struct PondRequirement: Codable, Sendable, Hashable {
    public var kind: String
    public var id: String?
    public var path: String?

    public init(kind: String, id: String? = nil, path: String? = nil) {
        self.kind = kind; self.id = id; self.path = path
    }
}

/// `item.requirements` (Pond 1.3.0): what's left before the owner's Done, and whether it may go.
public struct PondRequirements: Codable, Sendable, Equatable {
    public var left: [PondRequirement]
    public var ready: Bool

    public init(left: [PondRequirement], ready: Bool) {
        self.left = left; self.ready = ready
    }
}

/// The fields of the mailbox's item envelope that Hook uses.
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
    /// The current revision (Pond 1.1.0); nil from an older Pond or This Mac mode.
    public var revision: ServedRevision? = nil
    /// What the owner's Done still waits for (Pond 1.3.0), on `GET /asks/{id}` and the routes that
    /// answer one item; nil on an ask without requirements, from `GET /asks`, or an older Pond.
    public var requirements: PondRequirements? = nil

    enum CodingKeys: String, CodingKey {
        case id, title, status, projectId, created, updated, payload, completedAt, revision, requirements
    }

    public init(id: String, title: String, status: String, projectId: String? = nil, created: String, updated: String,
                payload: Payload, completedAt: String? = nil, revision: ServedRevision? = nil,
                requirements: PondRequirements? = nil) {
        self.id = id; self.title = title; self.status = status; self.projectId = projectId
        self.created = created; self.updated = updated; self.payload = payload; self.completedAt = completedAt
        self.revision = revision; self.requirements = requirements
    }

    /// As the synthesized decoder did, plus a lenient `revision` and `requirements`: a malformed
    /// one is nil, so the ask reads as one from an older Pond rather than failing the list.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        status = try c.decode(String.self, forKey: .status)
        projectId = try c.decodeIfPresent(String.self, forKey: .projectId)
        created = try c.decode(String.self, forKey: .created)
        updated = try c.decode(String.self, forKey: .updated)
        payload = try c.decode(Payload.self, forKey: .payload)
        completedAt = try c.decodeIfPresent(String.self, forKey: .completedAt)
        revision = (try? c.decodeIfPresent(ServedRevision.self, forKey: .revision)) ?? nil
        requirements = (try? c.decodeIfPresent(PondRequirements.self, forKey: .requirements)) ?? nil
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
    /// The revision the act was bound to (Pond 1.1.0); nil before, or for an unbound act.
    public var rev: Int?
    /// How the Pond checked the owner: "owner-key" or "token"; nil before Pond 1.1.0.
    public var auth: String?

    public init(seq: Int, itemId: String, kind: String, actor: String, text: String? = nil, at: String,
                rev: Int? = nil, auth: String? = nil) {
        self.seq = seq; self.itemId = itemId; self.kind = kind; self.actor = actor; self.text = text; self.at = at
        self.rev = rev; self.auth = auth
    }

    /// The kinds an owner's action records: a reply, a step answer, a close, a reopen, a
    /// problem report, an accepted correction or a message to the session.
    public static let ownerKinds: Set<String> = ["reply", "answer", "resolved", "declined", "reopened", "problem",
                                                 "accepted", "message"]
    /// The kinds that change whether an ask is open: a close or a reopen.
    public static let statusKinds: Set<String> = ["resolved", "declined", "reopened"]

    public var isOwnerEvent: Bool { actor == "owner" && Self.ownerKinds.contains(kind) }
}

/// `GET /asks/{id}`.
public struct AskDetail: Codable, Sendable, Equatable {
    public var item: WireItem
    public var events: [Event]
    /// Every revision, oldest first (Pond 1.1.0); [] from an older Pond or This Mac mode.
    public var revisions: [Revision]

    enum CodingKeys: String, CodingKey {
        case item, events, revisions
    }

    public init(item: WireItem, events: [Event], revisions: [Revision] = []) {
        self.item = item; self.events = events; self.revisions = revisions
    }

    /// `revisions` is [] when absent or malformed.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        item = try c.decode(WireItem.self, forKey: .item)
        events = try c.decode([Event].self, forKey: .events)
        revisions = (try? c.decodeIfPresent([Revision].self, forKey: .revisions)) ?? []
    }

    /// The owner's replies, oldest first.
    public var ownerReplies: [String] {
        events.filter { $0.kind == "reply" && $0.actor == "owner" }.compactMap(\.text)
    }

    /// Every owner event (reply, answer, resolved, declined, reopened), oldest first.
    public var ownerEvents: [Event] {
        events.filter(\.isOwnerEvent)
    }
}

// MARK: - The owner key (Pond 1.1.0)

/// One key in `GET /owner`'s `keys`: never its hash or code.
public struct OwnerKeyRow: Decodable, Sendable, Equatable {
    public var id: String
    public var label: String
    /// "pending" or "approved" (the Pond lists only those).
    public var status: String
    public var created: String
    public var approvedAt: String?

    public init(id: String, label: String, status: String, created: String, approvedAt: String? = nil) {
        self.id = id; self.label = label; self.status = status; self.created = created; self.approvedAt = approvedAt
    }
}

/// The key the request was sent with, in any status ("pending", "approved", "rejected", "revoked", …).
public struct OwnerSelf: Decodable, Sendable, Equatable {
    public var id: String
    public var status: String

    public init(id: String, status: String) { self.id = id; self.status = status }
}

/// `GET /owner`: whether owner acts need a key, the approved and pending keys, and this Mac's.
public struct OwnerStatus: Decodable, Sendable, Equatable {
    public var required: Bool
    public var keys: [OwnerKeyRow]
    /// This Mac's key, when the request carried one the Pond knows; nil otherwise.
    public var self_: OwnerSelf?

    enum CodingKeys: String, CodingKey {
        case required, keys
        case self_ = "self"
    }

    public init(required: Bool, keys: [OwnerKeyRow], self_: OwnerSelf? = nil) {
        self.required = required; self.keys = keys; self.self_ = self_
    }
}

/// `POST /owner/enroll` (`id`, `code`, `expires`, `status`) or `GET /owner/enroll/{id}` (`id`, `status`).
public struct Enrollment: Decodable, Sendable, Equatable {
    public var id: String
    /// The 6-digit code Hook shows and the Telegram request repeats.
    public var code: String?
    /// "pending", "approved", "rejected" or "expired".
    public var status: String?
    public var expires: String?

    public init(id: String, code: String? = nil, status: String? = nil, expires: String? = nil) {
        self.id = id; self.code = code; self.status = status; self.expires = expires
    }
}

/// `POST /owner/require`'s outcome: on and off at once, or off waiting for the owner's tap on Telegram.
public enum OwnerKeyRequirement: Equatable, Sendable {
    case on, off, pending
}
