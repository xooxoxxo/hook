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

    /// The leaves a tick applies to: those without a question.
    public static func tickable(_ nodes: [DetailModel.Node]) -> [DetailModel.Node] {
        leaves(of: nodes).filter { !$0.asks }
    }

    /// A question node is done once answered; any other item once ticked.
    public static func isDone(_ node: DetailModel.Node, ticks: Set<String>) -> Bool {
        node.asks ? node.answer != nil : ticks.contains(node.path)
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

    /// A leaf flips; a question leaf is left as it is. A parent ticks every sub-step
    /// without a question when any of those is unticked, else unticks them all.
    public static func toggle(_ node: DetailModel.Node, ticks: Set<String>) -> Set<String> {
        var next = ticks
        guard node.isParent else {
            guard !node.asks else { return ticks }
            if next.contains(node.path) { next.remove(node.path) } else { next.insert(node.path) }
            return next
        }
        let paths = node.children.filter { !$0.asks }.map(\.path)
        if paths.allSatisfy(next.contains) {
            next.subtract(paths)
        } else {
            next.formUnion(paths)
        }
        return next
    }

    /// ⌘T: ticks the current leaf; `path` is the leaf it ticked. nil, with the ticks
    /// unchanged, when every item is done or the current item is a question (which
    /// only an answer completes).
    public static func tickCurrent(ticks: Set<String>, nodes: [DetailModel.Node]) -> (ticks: Set<String>, path: String?) {
        guard let current = currentStep(ticks: ticks, nodes: nodes),
              tickable(nodes).contains(where: { $0.path == current }) else { return (ticks, nil) }
        return (ticks.union([current]), current)
    }

    /// ⇧⌘T: unticks the leaf ticked last this session (the last of `history` still
    /// ticked); with none, the last ticked leaf in order. Question leaves are skipped.
    public static func untickLast(ticks: Set<String>, history: [String], nodes: [DetailModel.Node]) -> (ticks: Set<String>, path: String?) {
        let leafPaths = tickable(nodes).map(\.path)
        let target = history.last { ticks.contains($0) && leafPaths.contains($0) }
            ?? leafPaths.last { ticks.contains($0) }
        guard let target else { return (ticks, nil) }
        return (ticks.subtracting([target]), target)
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

    /// "Send & Done" while step answers are unsent, the reply field has text, or a picked
    /// choice isn't the latest sent one.
    public static func primaryAction(draft: String?, choice: Int?, sent: Int?, unsentAnswers: Int = 0) -> PrimaryAction {
        if unsentAnswers > 0 { return .sendAndDone }
        if let draft, !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .sendAndDone }
        if let choice, choice != sent { return .sendAndDone }
        return .done
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
