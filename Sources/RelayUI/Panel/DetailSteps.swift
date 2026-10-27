import RelayCore
import SwiftUI

/// The Steps section: heading with the leaf count, then one inset grouped list with a row
/// per node: a step, a parent with its sub-step rows, verify last. Rows after an unfinished
/// blocking step are locked (Flow.lockedPaths). Ticks and expansion live in the model (ticks
/// in UserDefaults; done and upcoming rows opened by hand in memory), so they survive back and forth.
struct DetailSteps<Model: PanelViewModel>: View {
    @ObservedObject private var model: Model
    let snapshot: DetailSnapshot
    let nodes: [DetailModel.Node]
    let readOnly: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(model: Model, snapshot: DetailSnapshot, nodes: [DetailModel.Node], readOnly: Bool) {
        _model = ObservedObject(wrappedValue: model)
        self.snapshot = snapshot
        self.nodes = nodes
        self.readOnly = readOnly
    }

    static func progressText(_ progress: StepProgress) -> String {
        "\(progress.done) of \(progress.total) done"
    }

    /// "3. Create the Slack app", "3a. Click Create New App" (the VoiceOver rotor).
    static func rotorTitle(_ node: DetailModel.Node) -> String {
        node.label + ". " + line(node.content.action)
    }

    static func toggled(_ paths: Set<String>?, path: String, expanded: Bool) -> Set<String> {
        var paths = paths ?? []
        if expanded { paths.insert(path) } else { paths.remove(path) }
        return paths
    }

    /// A parent only with sub-steps: `substeps: []` decodes as an empty list and is a plain step.
    static func rendersAsParent(_ node: DetailModel.Node) -> Bool {
        !node.children.isEmpty
    }

    /// The Steps rotor's entries: every node that is on screen and not locked, in reading
    /// order. A parent's sub-step rows are rendered only while the parent row is open (it holds
    /// the current item, or was opened by hand), so they are left out otherwise; the parent
    /// itself stays. A parent's own question counts too (Flow.parentProgress).
    static func rotorNodes(_ nodes: [DetailModel.Node], ticks: Set<String>, current: String?,
                           expanded: Set<String>, locked: Set<String> = []) -> [DetailModel.Node] {
        nodes.flatMap { node -> [DetailModel.Node] in
            guard !locked.contains(node.path) else { return [] }
            guard rendersAsParent(node) else { return [node] }
            let open = StepRow.isOpen(state: parentState(node, ticks: ticks, current: current), locked: false,
                                      expanded: expanded.contains(node.path))
            return open ? [node] + node.children.filter { !locked.contains($0.path) } : [node]
        }
    }

    /// A parent row's state: done when every item is, current while it holds the current item.
    static func parentState(_ node: DetailModel.Node, ticks: Set<String>, current: String?) -> StepState {
        let progress = Flow.parentProgress(node, ticks: ticks)
        let holds = current != nil && (node.path == current || node.children.contains { $0.path == current })
        return ParentStepView.rowState(allDone: progress.done == progress.total, holdsCurrent: holds)
    }

    private var locked: Set<String> { Set(Flow.lockedPaths(nodes: nodes, ticks: snapshot.ticks)) }
    private var lockText: String? { Flow.lockText(nodes: nodes, ticks: snapshot.ticks) }

    /// "Step 3 of 5": top-level steps plus verify.
    private var total: Int { snapshot.model?.stepTotal ?? nodes.count }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.step) {
            HStack(alignment: .firstTextBaseline) {
                Text("Steps")
                    .font(DS.Font.heading)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityHeading(.h2)
                Spacer()
                Text(Self.progressText(snapshot.progress))
                    .font(DS.Font.meta)
                    .foregroundStyle(DS.Color.secondary)
                    .monospacedDigit()
            }
            StepGroup {
                let locked = locked, lockText = lockText
                ForEach(Array(nodes.enumerated()), id: \.element.id) { index, node in
                    if index > 0 { GroupDivider() }
                    nodeView(node, locked: locked, lockText: lockText)
                        .id(node.path)
                        .background(GeometryReader { geometry in
                            Color.clear.preference(key: NodeFramesKey.self,
                                                   value: [node.path: geometry.frame(in: .named(detailScrollSpace))])
                        })
                }
            }
        }
        .animation(DS.motion(DS.Motion.step, reduce: reduceMotion), value: snapshot.current)
        .animation(DS.motion(DS.Motion.step, reduce: reduceMotion), value: snapshot.ticks)
        .accessibilityRotor("Steps") {
            ForEach(Self.rotorNodes(nodes, ticks: snapshot.ticks, current: snapshot.current,
                                    expanded: (model.expandedDone[snapshot.id] ?? [])
                                        .union(model.expandedTodo[snapshot.id] ?? []),
                                    locked: locked)) { node in
                AccessibilityRotorEntry(Text(Self.rotorTitle(node)), id: node.path)
            }
        }
    }

    @ViewBuilder private func nodeView(_ node: DetailModel.Node, locked: Set<String>, lockText: String?) -> some View {
        let lock = { (path: String) in locked.contains(path) ? lockText : nil }
        if Self.rendersAsParent(node) {
            ParentStepView(
                content: node.content, number: node.number, total: total,
                children: node.children.map(\.content),
                childPaths: node.children.map(\.path),
                childStates: node.children.map { Flow.state(of: $0, ticks: snapshot.ticks, current: snapshot.current) },
                readOnly: readOnly,
                expanded: expanded(node.path, state: Self.parentState(node, ticks: snapshot.ticks, current: snapshot.current)),
                childExpanded: { index in
                    let child = node.children[index]
                    return expanded(child.path, state: Flow.state(of: child, ticks: snapshot.ticks, current: snapshot.current))
                },
                childQuestions: node.children.map(question),
                question: question(node),
                ownState: node.asks ? Flow.state(of: node, ticks: snapshot.ticks, current: snapshot.current) : nil,
                lockText: lock(node.path),
                childLockTexts: node.children.map { lock($0.path) },
                onToggleParent: { model.toggleTick(node.path, in: snapshot.id) },
                onToggleChild: { index in model.toggleTick(node.children[index].path, in: snapshot.id) },
                onCopy: { model.shell.copy($0) })
        } else {
            let state = Flow.state(of: node, ticks: snapshot.ticks, current: snapshot.current)
            StepView(
                content: node.content, level: node.level, state: state,
                total: total, readOnly: readOnly, expanded: expanded(node.path, state: state),
                question: question(node), lockText: lock(node.path),
                onToggle: { model.toggleTick(node.path, in: snapshot.id) },
                onCopy: { model.shell.copy($0) })
        }
    }

    /// The node's question block, with its draft bound to `model.answerDrafts[id][path]`.
    private func question(_ node: DetailModel.Node) -> StepQuestion? {
        guard let question = node.question else { return nil }
        let id = snapshot.id, path = node.path
        let draft = Binding<AnswerDraft?>(
            get: { model.answerDrafts[id]?[path] },
            set: { value in
                var drafts = model.answerDrafts[id] ?? [:]
                drafts[path] = value
                model.answerDrafts[id] = drafts.isEmpty ? nil : drafts
            })
        return StepQuestion(question: question, answer: node.answer, draft: draft, readOnly: readOnly,
                            sending: snapshot.answerState == .sending,
                            onSend: { model.sendAnswer(id, path: path) })
    }

    /// A row's hand-opened state, by path: a done row's in `model.expandedDone[id]`, an
    /// upcoming row's in `model.expandedTodo[id]`, so ticking a step it was opened as upcoming
    /// doesn't leave it open once done. The current row ignores it (always open).
    private func expanded(_ path: String, state: StepState) -> Binding<Bool> {
        let id = snapshot.id
        if state == .done {
            return Binding(
                get: { model.expandedDone[id]?.contains(path) ?? false },
                set: { model.expandedDone[id] = Self.toggled(model.expandedDone[id], path: path, expanded: $0) })
        }
        return Binding(
            get: { model.expandedTodo[id]?.contains(path) ?? false },
            set: { model.expandedTodo[id] = Self.toggled(model.expandedTodo[id], path: path, expanded: $0) })
    }
}
