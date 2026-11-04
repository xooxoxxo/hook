import Foundation

/// A value of the ask's `done` list (Pond 1.3.0).
public enum DoneRequirement: String, Sendable, CaseIterable {
    /// Every step that isn't optional is finished.
    case steps
    /// The reply prompt is answered.
    case reply
    /// The owner sent the session a message.
    case message

    /// The known values of a raw `done` list; anything else is ignored.
    public static func parse(_ raw: [String]?) -> Set<DoneRequirement> {
        Set((raw ?? []).compactMap(DoneRequirement.init(rawValue:)))
    }
}

/// One thing the owner's Done waits for.
public enum RequirementItem: Hashable, Sendable {
    /// A step or sub-step, by display path ("2", "3.1") and stable id.
    case step(path: String, id: String?)
    case reply
    case message
}

/// What an ask needs before the owner's Done, and what of it is still left.
public struct RequirementState: Equatable, Sendable {
    public static let none = RequirementState(items: [], left: [])

    /// Everything required, in document order: steps, then the reply, then a message.
    public var items: [RequirementItem]
    public var left: [RequirementItem]
    /// The paths of the steps left that their own answer alone would finish: a required
    /// question, or a parent whose only unfinished part is its question (`doneAvailable`).
    public var answerable: Set<String>

    public init(items: [RequirementItem], left: [RequirementItem], answerable: Set<String> = []) {
        self.items = items
        self.left = left
        self.answerable = answerable
    }

    public var hasAny: Bool { !items.isEmpty }
    public var ready: Bool { left.isEmpty }

    /// A required step or sub-step that isn't finished yet: its row carries the mark.
    public func marks(_ path: String) -> Bool {
        left.contains { if case .step(let p, _) = $0 { return p == path } else { return false } }
    }

    /// `done` holds "reply" and the owner hasn't replied yet.
    public var marksReply: Bool { left.contains(.reply) }

    /// `done` holds "message" and the ask's events hold no owner message yet.
    public var marksMessages: Bool { left.contains(.message) }
}

/// The rules for "required before Done" (Pond 1.3.0), the twin of the Pond's
/// `mailbox/requirements.py`. Hook checks them against its own ticks and the ask's events; the
/// Pond stays authoritative and refuses an owner Done with 409 `requirements_unmet`.
public enum Requirements {
    /// The ask says anything is required: a step or sub-step with `required: true`, or a
    /// known value in `done`. Read from the instructable alone, before any detail is loaded.
    public static func declared(_ ins: Instructable?) -> Bool {
        guard let ins else { return false }
        if !DoneRequirement.parse(ins.done).isEmpty { return true }
        return ins.steps.contains { step in
            step.required == true || (step.substeps ?? []).contains { $0.required == true }
        }
    }

    /// What's required and what's left (RD 5): a step is finished as `Flow.isFinished` says (a
    /// leaf ticked or answered; a parent with its own answer and every sub-step that isn't
    /// optional); the reply once the owner replied; a message once the ask holds an owner message.
    public static func state(_ model: DetailModel, ticks: Set<String>) -> RequirementState {
        var items: [RequirementItem] = []
        var left: [RequirementItem] = []
        var answerable: Set<String> = []
        for node in Flow.flattened(model.nodes) where node.isRequired && !node.isVerify {
            let item = RequirementItem.step(path: node.path, id: node.stepID)
            items.append(item)
            guard !Flow.isFinished(node, ticks: ticks) else { continue }
            left.append(item)
            if node.asks, node.children.allSatisfy({ $0.isOptional || Flow.isDone($0, ticks: ticks) }) {
                answerable.insert(node.path)
            }
        }
        if model.done.contains(.reply) {
            items.append(.reply)
            if model.ownerReplies.isEmpty { left.append(.reply) }
        }
        if model.done.contains(.message) {
            items.append(.message)
            if model.ownerMessages.isEmpty { left.append(.message) }
        }
        return RequirementState(items: items, left: left, answerable: answerable)
    }

    /// Done may be pressed: nothing is left, or every item left is covered by a draft that
    /// Send & Done sends first (RD 22): a required question (a leaf, or a parent whose only
    /// unfinished part is its own question) by an unsent answer, the reply by a reply draft.
    /// A tick or a message is never covered.
    public static func doneAvailable(_ state: RequirementState, unsent: UnsentAnswers, replyUnsent: Bool) -> Bool {
        let drafted = Set(unsent.paths)
        return state.left.allSatisfy { item in
            switch item {
            case .step(let path, _): return drafted.contains(path) && state.answerable.contains(path)
            case .reply: return replyUnsent
            case .message: return false
            }
        }
    }

    /// The tick changes between two tick sets, as step ids, each list sorted. Paths without a
    /// step id (an ask posted before Pond 1.1.0) and verify are left out.
    public static func delta(nodes: [DetailModel.Node], before: Set<String>,
                             after: Set<String>) -> (tick: [String], untick: [String]) {
        let ids = Dictionary(Flow.flattened(nodes).filter { !$0.isVerify }.compactMap { node in
            node.stepID.map { (node.path, $0) }
        }) { first, _ in first }
        let tick = after.subtracting(before).compactMap { ids[$0] }
        let untick = before.subtracting(after).compactMap { ids[$0] }
        return (Array(Set(tick)).sorted(), Array(Set(untick)).sorted())
    }

    /// The ids of the steps the Pond lists as left whose ticks Hook has (RD 11, 13): Hook sends
    /// them again. A parent's are its ticked sub-steps. In document order, each once.
    public static func behind(_ pond: [PondRequirement], nodes: [DetailModel.Node], ticks: Set<String>) -> [String] {
        let wanted = Set(pond.filter { $0.kind == "step" }.compactMap(\.id))
        guard !wanted.isEmpty else { return [] }
        var out: [String] = []
        for node in nodes where !node.isVerify {
            for candidate in [node] + node.children {
                let inLeft = candidate.stepID.map(wanted.contains) == true
                    || (candidate.kind == .sub && node.stepID.map(wanted.contains) == true)
                guard inLeft, Flow.canTick(candidate), !candidate.isParent, ticks.contains(candidate.path),
                      let id = candidate.stepID, !out.contains(id) else { continue }
                out.append(id)
            }
        }
        return out
    }

    /// Done's help and VoiceOver hint while it is off.
    public static func doneHelp(_ state: RequirementState) -> String {
        "Done turns on once the marked items are finished. Skip always works."
    }
}
