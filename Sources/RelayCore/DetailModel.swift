import Foundation

/// What the detail view shows for one ask. Strings stay raw; the
/// view passes every one through `Sanitize`.
public struct DetailModel: Sendable, Equatable {
    /// One timeline entry: a step, or the verify check (always last).
    public struct Node: Sendable, Equatable {
        /// 0-based position in the timeline; also the tick number.
        public var index: Int
        public var isVerify: Bool
        public var action: String
        public var place: String?
        public var code: String?
        public var lang: String?
        public var expect: String?
        public var url: String?

        public init(index: Int, isVerify: Bool = false, action: String, place: String? = nil,
                    code: String? = nil, lang: String? = nil, expect: String? = nil, url: String? = nil) {
            self.index = index
            self.isVerify = isVerify
            self.action = action
            self.place = place
            self.code = code
            self.lang = lang
            self.expect = expect
            self.url = url
        }
    }

    public var id: String
    public var title: String
    public var why: String?
    /// Text of a legacy ask's `steps` events; empty for instructables.
    public var notes: [String]
    /// "host · cwd · session" from `instructable.from`, present parts only.
    public var provenance: String?
    public var project: String
    public var urgency: String
    public var nodes: [Node]
    public var links: [LinkRef]
    public var reply: ReplySpec?
    public var ownerReplies: [String]
    public var isOpen: Bool
    /// Actor and time of the last resolved/declined event, when not open.
    public var closedBy: String?
    public var closedAt: String?

    public static func make(_ detail: AskDetail) -> DetailModel {
        make(item: detail.item, events: detail.events)
    }

    public static func make(item: WireItem, events: [Event]) -> DetailModel {
        var why: String?
        var notes: [String] = []
        var provenance: String?
        var nodes: [Node] = []
        var links: [LinkRef] = []
        var reply: ReplySpec?

        if let ins = item.instructable {
            why = present(ins.why)
            for step in ins.steps {
                nodes.append(node(step, index: nodes.count, isVerify: false))
            }
            if let verify = ins.verify {
                nodes.append(node(verify, index: nodes.count, isVerify: true))
            }
            links = ins.links ?? []
            reply = ins.reply
            if let from = ins.from {
                let parts = [from.host, from.cwd, from.session].compactMap(present)
                provenance = parts.isEmpty ? nil : parts.joined(separator: " · ")
            }
        } else {
            // A legacy ask (posted without an instructable): why, cmd, link, steps events.
            why = present(item.payload.why)
            if let cmd = present(item.payload.cmd) {
                nodes.append(Node(index: 0, action: "Run this", code: cmd))
            }
            if let link = present(item.payload.link) {
                links = [LinkRef(label: "Link", url: link)]
            }
            notes = events.filter { $0.kind == "steps" }.compactMap { present($0.text) }
        }

        let isOpen = item.status == "open"
        let closing = isOpen ? nil : events.last { $0.kind == "resolved" || $0.kind == "declined" }

        return DetailModel(
            id: item.id,
            title: item.title,
            why: why,
            notes: notes,
            provenance: provenance,
            project: item.projectId ?? "",
            urgency: item.urgency,
            nodes: nodes,
            links: links,
            reply: reply,
            ownerReplies: events.filter { $0.kind == "reply" && $0.actor == "owner" }.compactMap(\.text),
            isOpen: isOpen,
            closedBy: closing?.actor,
            closedAt: closing?.at)
    }

    private static func node(_ step: Step, index: Int, isVerify: Bool) -> Node {
        Node(index: index, isVerify: isVerify, action: step.action, place: present(step.place),
             code: present(step.code), lang: present(step.lang), expect: present(step.expect),
             url: present(step.url))
    }

    /// The value unchanged, or nil when it is absent or only whitespace.
    private static func present(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }
}

/// Ticked timeline nodes, per source and ask, in UserDefaults as `[Int]`
/// under `relay.ticks.<sourceKey>.<id>`.
public enum Ticks {
    static let prefix = "relay.ticks."

    public static func key(sourceKey: String, id: String) -> String {
        prefix + sourceKey + "." + id
    }

    public static func load(_ defaults: UserDefaults, sourceKey: String, id: String) -> Set<Int> {
        let stored = defaults.array(forKey: key(sourceKey: sourceKey, id: id)) as? [Int] ?? []
        return Set(stored.filter { $0 >= 0 })
    }

    /// An empty set removes the key.
    public static func save(_ defaults: UserDefaults, sourceKey: String, id: String, ticks: Set<Int>) {
        let key = key(sourceKey: sourceKey, id: id)
        if ticks.isEmpty {
            defaults.removeObject(forKey: key)
        } else {
            defaults.set(ticks.sorted(), forKey: key)
        }
    }

    /// Removes this source's keys whose id isn't in `ids`. Call it only after a
    /// successful list of the same source. Ids never contain ".", so a remainder
    /// with a dot belongs to another source whose key starts the same way.
    public static func prune(_ defaults: UserDefaults, sourceKey: String, keep ids: Set<String>) {
        let own = prefix + sourceKey + "."
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(own) {
            let id = String(key.dropFirst(own.count))
            if !id.contains("."), !ids.contains(id) {
                defaults.removeObject(forKey: key)
            }
        }
    }
}
