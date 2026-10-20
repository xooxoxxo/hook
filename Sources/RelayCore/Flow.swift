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
public enum Flow {
    /// Each step's sub-steps when it has them, else the step; then verify.
    public static func leaves(of nodes: [DetailModel.Node]) -> [DetailModel.Node] {
        nodes.flatMap { $0.children.isEmpty ? [$0] : $0.children }
    }

    /// Every node in reading order: a step, then its sub-steps, …, then verify.
    public static func flattened(_ nodes: [DetailModel.Node]) -> [DetailModel.Node] {
        nodes.flatMap { [$0] + $0.children }
    }

    public static func currentStep(ticks: Set<String>, nodes: [DetailModel.Node]) -> String? {
        leaves(of: nodes).first { !ticks.contains($0.path) }?.path
    }

    public static func progress(ticks: Set<String>, nodes: [DetailModel.Node]) -> StepProgress {
        let all = leaves(of: nodes)
        return StepProgress(done: all.filter { ticks.contains($0.path) }.count, total: all.count)
    }

    public static func state(of leaf: DetailModel.Node, ticks: Set<String>, current: String?) -> StepState {
        if ticks.contains(leaf.path) { return .done }
        return leaf.path == current ? .current : .todo
    }

    public static func parentProgress(_ parent: DetailModel.Node, ticks: Set<String>) -> StepProgress {
        StepProgress(done: parent.children.filter { ticks.contains($0.path) }.count, total: parent.children.count)
    }

    /// A leaf flips. A parent ticks every sub-step when any is unticked, else unticks them all.
    public static func toggle(_ node: DetailModel.Node, ticks: Set<String>) -> Set<String> {
        var next = ticks
        guard node.isParent else {
            if next.contains(node.path) { next.remove(node.path) } else { next.insert(node.path) }
            return next
        }
        let paths = node.children.map(\.path)
        if paths.allSatisfy(next.contains) {
            next.subtract(paths)
        } else {
            next.formUnion(paths)
        }
        return next
    }

    /// ⌘T: ticks the current leaf; `path` is the leaf it ticked, nil when all are ticked.
    public static func tickCurrent(ticks: Set<String>, nodes: [DetailModel.Node]) -> (ticks: Set<String>, path: String?) {
        guard let current = currentStep(ticks: ticks, nodes: nodes) else { return (ticks, nil) }
        return (ticks.union([current]), current)
    }

    /// ⇧⌘T: unticks the leaf ticked last this session (the last of `history` still
    /// ticked); with none, the last ticked leaf in order.
    public static func untickLast(ticks: Set<String>, history: [String], nodes: [DetailModel.Node]) -> (ticks: Set<String>, path: String?) {
        let leafPaths = leaves(of: nodes).map(\.path)
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

    /// "Send & Done" while the reply field has text or a picked choice isn't the latest sent one.
    public static func primaryAction(draft: String?, choice: Int?, sent: Int?) -> PrimaryAction {
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

    /// The paths whose frame (in the scroll view's coordinates) overlaps the band from
    /// `top` (below the header) to `bottom` (above the bars).
    public static func visible(frames: [String: CGRect], top: CGFloat, bottom: CGFloat) -> Set<String> {
        Set(frames.filter { $0.value.maxY > top && $0.value.minY < bottom }.keys)
    }
}
