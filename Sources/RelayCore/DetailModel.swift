import Foundation

/// What the detail view shows for one ask. Strings stay raw; the
/// view passes every one through `Sanitize`.
public struct DetailModel: Sendable, Equatable {
    /// One node of the step tree: a step, one of its sub-steps, or verify (always last).
    public struct Node: Sendable, Equatable, Identifiable {
        /// "3", "3.2" (second sub-step of step 3), "verify". The tick key.
        public var path: String
        /// "3", "3b", "Verify".
        public var label: String
        public var kind: StepFingerprint.Kind
        /// The 1-based top-level number; a sub-step carries its parent's; verify is steps.count + 1.
        public var number: Int
        /// Raw values, blank ones already nil.
        public var content: StepContent
        public var children: [Node]
        public var fingerprint: String

        public init(path: String, label: String, kind: StepFingerprint.Kind, number: Int, content: StepContent,
                    children: [Node] = [], fingerprint: String) {
            self.path = path
            self.label = label
            self.kind = kind
            self.number = number
            self.content = content
            self.children = children
            self.fingerprint = fingerprint
        }

        public var id: String { path }
        public var isVerify: Bool { kind == .verify }
        public var isParent: Bool { !children.isEmpty }

        public var level: StepLevel {
            switch kind {
            case .step: return .top(number)
            case .verify: return .verify
            case .sub:
                let position = path.split(separator: ".").last.flatMap { Int($0) } ?? 1
                return .sub(number, position - 1)
            }
        }

        public var action: String { content.action }
        public var place: String? { content.place }
        public var code: String? { content.code }
        public var lang: String? { content.lang }
        public var expect: String? { content.expect }
        public var detail: String? { content.detail }
        public var url: String? { content.url }
    }

    public var id: String
    public var title: String
    public var why: String?
    /// Text of a legacy ask's `steps` events; empty for instructables.
    public var notes: [String]
    /// Where the ask came from (`instructable.from`), when it says anything usable.
    public var origin: AskOrigin?
    public var project: String
    public var urgency: String
    public var nodes: [Node]
    public var links: [LinkRef]
    public var reply: ReplySpec?
    public var ownerReplies: [String]
    public var isOpen: Bool
    /// Actor and time of the last resolved/declined event, when not open and not
    /// reopened since.
    public var closedBy: String?
    public var closedAt: String?

    /// Top-level steps plus verify: the "of 5" in "Step 3 of 5".
    public var stepTotal: Int { nodes.count }

    /// Steps in order, each with its sub-steps (at most ten), then verify.
    public static func nodes(steps: [Step], verify: Step?) -> [Node] {
        var nodes: [Node] = []
        for (index, step) in steps.enumerated() {
            let number = index + 1
            let content = content(step)
            let fingerprint = StepFingerprint.make(kind: .step, action: step.action, place: content.place, code: content.code)
            let subs = (step.substeps ?? []).prefix(StepLevel.letters.count).enumerated().map { position, sub in
                let subContent = Self.content(sub)
                return Node(
                    path: "\(number).\(position + 1)", label: "\(number)" + StepLevel.letters[position], kind: .sub,
                    number: number, content: subContent,
                    fingerprint: StepFingerprint.make(kind: .sub, action: sub.action, place: subContent.place,
                                                      code: subContent.code, parent: fingerprint))
            }
            nodes.append(Node(path: "\(number)", label: "\(number)", kind: .step, number: number, content: content,
                              children: Array(subs), fingerprint: fingerprint))
        }
        if let verify {
            let content = content(verify)
            nodes.append(Node(
                path: "verify", label: "Verify", kind: .verify, number: steps.count + 1, content: content,
                fingerprint: StepFingerprint.make(kind: .verify, action: verify.action, place: content.place, code: content.code)))
        }
        return nodes
    }

    private static func content(_ step: Step) -> StepContent {
        StepContent(action: step.action, place: present(step.place), detail: present(step.detail), url: present(step.url),
                    code: present(step.code), lang: present(step.lang), expect: present(step.expect))
    }

    public static func make(_ detail: AskDetail) -> DetailModel {
        make(item: detail.item, events: detail.events)
    }

    public static func make(item: WireItem, events: [Event]) -> DetailModel {
        var why: String?
        var notes: [String] = []
        var origin: AskOrigin?
        var nodes: [Node] = []
        var links: [LinkRef] = []
        var reply: ReplySpec?

        if let ins = item.instructable {
            why = present(ins.why)
            nodes = Self.nodes(steps: ins.steps, verify: ins.verify)
            links = ins.links ?? []
            reply = ins.reply
            origin = AskOrigin(from: ins.from)
        } else {
            // A legacy ask (posted without an instructable): why, cmd, link, steps events.
            why = present(item.payload.why)
            if let cmd = present(item.payload.cmd) {
                nodes = [Node(path: "1", label: "1", kind: .step, number: 1, content: StepContent(action: "Run this", code: cmd),
                              fingerprint: StepFingerprint.make(kind: .step, action: "Run this", place: nil, code: cmd))]
            }
            if let link = present(item.payload.link) {
                links = [LinkRef(label: "Link", url: link)]
            }
            notes = events.filter { $0.kind == "steps" }.compactMap { present($0.text) }
        }

        let isOpen = item.status == "open"
        // The last close or reopen decides; a reopened ask is never shown as closed.
        let lastStatus = isOpen ? nil : events.last { Event.statusKinds.contains($0.kind) }
        let closing = lastStatus?.kind == "reopened" ? nil : lastStatus

        return DetailModel(
            id: item.id,
            title: item.title,
            why: why,
            notes: notes,
            origin: origin,
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

    /// The value unchanged, or nil when it is absent or only whitespace.
    private static func present(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }
}
