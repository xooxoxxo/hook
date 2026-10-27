import Foundation

public struct StepProgress: Equatable, Sendable {
    public var done: Int
    public var total: Int

    public init(done: Int, total: Int) {
        self.done = done
        self.total = total
    }
}

/// The step and ask order rules. Tick state is keyed by leaf path; a
/// parent is never ticked as a unit, its state is derived from its sub-steps.
///
/// Questions: a node that asks a question is done once it has an answer
/// (`node.answer`), never by a tick, and can't be ticked. A parent's own question is
/// one more item, counted before its sub-steps.
///
/// Optional steps (`node.isOptional`): the owner may mark one done without doing it or
/// answering its question, so an optional question is done once ticked or answered, and
/// can be ticked (a parent's own optional question by its own path). An optional parent
/// makes its whole subtree optional (`DetailModel.nodes` marks its sub-steps optional and
/// never blocking), so ticking it ticks every sub-step, questions included, and finishes it.
public enum Flow {
    /// Each step's sub-steps when it has them, else the step; then verify.
    public static func leaves(of nodes: [DetailModel.Node]) -> [DetailModel.Node] {
        nodes.flatMap { $0.children.isEmpty ? [$0] : $0.children }
    }

    /// Every node in reading order: a step, then its sub-steps, …, then verify.
    public static func flattened(_ nodes: [DetailModel.Node]) -> [DetailModel.Node] {
        nodes.flatMap { [$0] + $0.children }
    }

    /// What "N of M" counts, in reading order: the leaves, plus each parent that asks
    /// a question, just before its sub-steps.
    public static func items(of nodes: [DetailModel.Node]) -> [DetailModel.Node] {
        nodes.flatMap { node -> [DetailModel.Node] in
            guard node.isParent else { return [node] }
            return (node.asks ? [node] : []) + node.children
        }
    }

    /// The items a tick applies to: the leaves without a question, plus every optional
    /// question (a parent's own one included).
    public static func tickable(_ nodes: [DetailModel.Node]) -> [DetailModel.Node] {
        items(of: nodes).filter(canTick)
    }

    /// A leaf without a question, or an optional item (a leaf, or a parent's own question).
    public static func canTick(_ node: DetailModel.Node) -> Bool {
        node.isParent ? node.asks && node.isOptional : !node.asks || node.isOptional
    }

    /// A question node is done once answered, an optional one also once ticked; any other
    /// item once ticked.
    public static func isDone(_ node: DetailModel.Node, ticks: Set<String>) -> Bool {
        guard node.asks else { return ticks.contains(node.path) }
        return node.answer != nil || (node.isOptional && ticks.contains(node.path))
    }

    /// The first item not done: an unanswered question stops it.
    public static func currentStep(ticks: Set<String>, nodes: [DetailModel.Node]) -> String? {
        items(of: nodes).first { !isDone($0, ticks: ticks) }?.path
    }

    public static func progress(ticks: Set<String>, nodes: [DetailModel.Node]) -> StepProgress {
        let all = items(of: nodes)
        return StepProgress(done: all.filter { isDone($0, ticks: ticks) }.count, total: all.count)
    }

    /// For a leaf, or for a parent's own question (pass the parent).
    public static func state(of leaf: DetailModel.Node, ticks: Set<String>, current: String?) -> StepState {
        if isDone(leaf, ticks: ticks) { return .done }
        return leaf.path == current ? .current : .todo
    }

    /// The sub-steps, plus the parent's own question when it asks one.
    public static func parentProgress(_ parent: DetailModel.Node, ticks: Set<String>) -> StepProgress {
        let all = (parent.asks ? [parent] : []) + parent.children
        return StepProgress(done: all.filter { isDone($0, ticks: ticks) }.count, total: all.count)
    }

    /// A leaf flips; a question leaf is left as it is unless optional. A parent ticks every
    /// tickable sub-step (and its own optional question) when any of those is unticked,
    /// else unticks them all.
    public static func toggle(_ node: DetailModel.Node, ticks: Set<String>) -> Set<String> {
        var next = ticks
        guard node.isParent else {
            guard canTick(node) else { return ticks }
            if next.contains(node.path) { next.remove(node.path) } else { next.insert(node.path) }
            return next
        }
        let paths = ([node] + node.children).filter(canTick).map(\.path)
        guard !paths.isEmpty else { return ticks }
        if paths.allSatisfy(next.contains) {
            next.subtract(paths)
        } else {
            next.formUnion(paths)
        }
        return next
    }

    /// ⌘T: ticks the current item; `path` is the one it ticked. nil, with the ticks
    /// unchanged, when every item is done or the current item is a required question
    /// (which only an answer completes). An optional question is ticked like a leaf.
    public static func tickCurrent(ticks: Set<String>, nodes: [DetailModel.Node]) -> (ticks: Set<String>, path: String?) {
        guard let current = currentStep(ticks: ticks, nodes: nodes),
              tickable(nodes).contains(where: { $0.path == current }),
              !lockedPaths(nodes: nodes, ticks: ticks).contains(current) else { return (ticks, nil) }
        return (ticks.union([current]), current)
    }

    /// ⇧⌘T: unticks the item ticked last this session (the last of `history` still
    /// ticked); with none, the last ticked item in order. Required questions are skipped, and so
    /// are `locked` ones (Flow.lockedPaths): a locked step is never ticked or unticked.
    public static func untickLast(ticks: Set<String>, history: [String], nodes: [DetailModel.Node],
                                  locked: Set<String> = []) -> (ticks: Set<String>, path: String?) {
        let leafPaths = tickable(nodes).map(\.path).filter { !locked.contains($0) }
        let target = history.last { ticks.contains($0) && leafPaths.contains($0) }
            ?? leafPaths.last { ticks.contains($0) }
        guard let target else { return (ticks, nil) }
        return (ticks.subtracting([target]), target)
    }
}

// MARK: Blocking steps

extension Flow {
    /// A blocking item is finished when `isDone` says so; a blocking parent also needs
    /// every required sub-step done, and its own answer when it asks a question (a parent
    /// is never ticked as a unit, so without a question its own part is always in). An
    /// optional sub-step never holds its blocking parent back.
    public static func isFinished(_ node: DetailModel.Node, ticks: Set<String>) -> Bool {
        guard node.isParent else { return isDone(node, ticks: ticks) }
        return (!node.asks || node.answer != nil)
            && node.children.allSatisfy { $0.isOptional || isDone($0, ticks: ticks) }
    }

    /// The first blocking step or sub-step, in reading order, that isn't finished; nil
    /// when none holds anything back.
    public static func firstOpenBlock(nodes: [DetailModel.Node], ticks: Set<String>) -> DetailModel.Node? {
        flattened(nodes).first { $0.isBlocking && !$0.isVerify && !isFinished($0, ticks: ticks) }
    }

    /// The paths that stay locked: every node, in reading order, after the first
    /// unfinished blocking item. A blocking parent keeps its own sub-steps open and
    /// locks what follows its last one; a blocking sub-step locks its later siblings,
    /// the steps after its parent and verify. Empty when nothing is blocked.
    public static func lockedPaths(nodes: [DetailModel.Node], ticks: Set<String>) -> [String] {
        guard let block = firstOpenBlock(nodes: nodes, ticks: ticks) else { return [] }
        let order = flattened(nodes)
        let last = block.children.last?.path ?? block.path
        guard let index = order.firstIndex(where: { $0.path == last }) else { return [] }
        return order[(index + 1)...].map(\.path)
    }

    /// A locked row's line: "Finish step 3 first", naming the blocking step or sub-step
    /// ("3a") that holds it back; nil when nothing is locked.
    public static func lockText(nodes: [DetailModel.Node], ticks: Set<String>) -> String? {
        firstOpenBlock(nodes: nodes, ticks: ticks).map { "Finish step \($0.label) first" }
    }

    /// The warning box's text when the step's own `warning` is missing.
    public static let blockingWarning = "Finish this before going on: the next steps depend on it."

    /// The warning box on a blocking node: its `warning`, else `blockingWarning`; nil when
    /// the node doesn't block.
    public static func warningText(_ node: DetailModel.Node) -> String? {
        node.isVerify ? nil : node.content.warningText
    }

    /// `toggle`, but a locked node is never ticked or unticked: a locked leaf (or parent) is
    /// left as it is, and a parent's toggle leaves out its locked sub-steps.
    public static func toggle(_ node: DetailModel.Node, ticks: Set<String>, locked: Set<String>) -> Set<String> {
        guard !locked.contains(node.path) else { return ticks }
        guard node.isParent else { return toggle(node, ticks: ticks) }
        var open = node
        open.children = node.children.filter { !locked.contains($0.path) }
        guard !open.children.isEmpty else { return ticks }
        return toggle(open, ticks: ticks)
    }
}

extension Flow {
    /// After Done or Skip on `id`: the next row below, else the one above, else nil.
    /// `id` not in the order (it was outside the filter): the first row, else nil.
    public static func nextAsk(after id: String, in visibleOrder: [String]) -> String? {
        guard let index = visibleOrder.firstIndex(of: id) else { return visibleOrder.first }
        if index + 1 < visibleOrder.count { return visibleOrder[index + 1] }
        if index > 0 { return visibleOrder[index - 1] }
        return nil
    }

    /// What is unsent: `.answer` while step answers are unsent, else `.reply` while the reply
    /// field has text other than the latest sent text (`sentText`, a Change prefill) or a
    /// picked choice isn't the latest sent one; nil when nothing is.
    public static func unsentKind(draft: String?, choice: Int?, sent: Int?, unsentAnswers: Int = 0,
                                  sentText: String? = nil) -> UnsentKind? {
        if unsentAnswers > 0 { return .answer }
        if let draft, AnswerEditing.isNewText(draft, sentText: sentText) { return .reply }
        if let choice, choice != sent { return .reply }
        return nil
    }

    /// `.sendAndDone` while anything is unsent (`unsentKind`): Done then warns before it
    /// closes. `.done` otherwise.
    public static func primaryAction(draft: String?, choice: Int?, sent: Int?, unsentAnswers: Int = 0,
                                     sentText: String? = nil) -> PrimaryAction {
        unsentKind(draft: draft, choice: choice, sent: sent, unsentAnswers: unsentAnswers, sentText: sentText) == nil
            ? .done : .sendAndDone
    }
}

// MARK: Scroll anchors

extension Flow {
    /// The anchor that restores a detail's scroll position: the first node in `order` that
    /// is on screen. nil when none is.
    public static func topVisible(visible: Set<String>, order: [String]) -> String? {
        order.first { visible.contains($0) }
    }

    /// After a tick, scroll to the new current leaf only when its top is at or below the
    /// visible area's bottom edge; a leaf already on screen (or above) stays put.
    public static func needsScroll(nodeTop: CGFloat, visibleBottom: CGFloat) -> Bool {
        nodeTop >= visibleBottom
    }

    /// The bottom edge of the visible band: the viewport minus the pinned bottom bars.
    /// `barHeight` is their measured height; 0 or less means not measured yet, so the
    /// designed height `fallback` applies.
    public static func visibleBottom(viewportHeight: CGFloat, barHeight: CGFloat, fallback: CGFloat) -> CGFloat {
        viewportHeight - (barHeight > 0 ? barHeight : fallback)
    }

    /// The paths whose frame (in the scroll view's coordinates) overlaps the band from
    /// `top` (below the header) to `bottom` (above the bars).
    public static func visible(frames: [String: CGRect], top: CGFloat, bottom: CGFloat) -> Set<String> {
        Set(frames.filter { $0.value.maxY > top && $0.value.minY < bottom }.keys)
    }
}
