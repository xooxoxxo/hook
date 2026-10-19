import RelayCore
import SwiftUI

/// The Steps section (design §4.4): heading with the leaf count, then each node: a step,
/// a parent with its indented sub-steps, verify last. Ticks and done-step expansion live
/// in the model (ticks in UserDefaults, expansion in memory), so they survive back and forth.
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

    /// "3. Create the Slack app", "3a. Click Create New App" (design §4.14 rotor).
    static func rotorTitle(_ node: DetailModel.Node) -> String {
        node.label + ". " + line(node.content.action)
    }

    static func toggled(_ paths: Set<String>?, path: String, expanded: Bool) -> Set<String> {
        var paths = paths ?? []
        if expanded { paths.insert(path) } else { paths.remove(path) }
        return paths
    }

    /// A parent only with sub-steps: `substeps: []` decodes as an empty list and is a plain step (Task 16 ruling).
    static func rendersAsParent(_ node: DetailModel.Node) -> Bool {
        !node.children.isEmpty
    }

    /// The Steps rotor's entries: every node that is on screen, in reading order. A parent whose
    /// sub-steps are all done collapses (ParentStepView) and its sub-step rows are not rendered
    /// unless the parent is expanded, so they are left out then; the parent itself stays.
    static func rotorNodes(_ nodes: [DetailModel.Node], ticks: Set<String>, current: String?,
                           expanded: Set<String>) -> [DetailModel.Node] {
        nodes.flatMap { node -> [DetailModel.Node] in
            guard rendersAsParent(node) else { return [node] }
            let allDone = node.children.allSatisfy { Flow.state(of: $0, ticks: ticks, current: current) == .done }
            return allDone && !expanded.contains(node.path) ? [node] : [node] + node.children
        }
    }

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
            VStack(alignment: .leading, spacing: DS.Space.step) {
                ForEach(nodes) { node in
                    nodeView(node)
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
                                    expanded: model.expandedDone[snapshot.id] ?? [])) { node in
                AccessibilityRotorEntry(Text(Self.rotorTitle(node)), id: node.path)
            }
        }
    }

    @ViewBuilder private func nodeView(_ node: DetailModel.Node) -> some View {
        if Self.rendersAsParent(node) {
            ParentStepView(
                content: node.content, number: node.number, total: total,
                children: node.children.map(\.content),
                childPaths: node.children.map(\.path),
                childStates: node.children.map { Flow.state(of: $0, ticks: snapshot.ticks, current: snapshot.current) },
                readOnly: readOnly,
                expanded: expanded(node.path),
                childExpanded: { index in expanded(node.children[index].path) },
                onToggleParent: { model.toggleTick(node.path, in: snapshot.id) },
                onToggleChild: { index in model.toggleTick(node.children[index].path, in: snapshot.id) },
                onCopy: { model.shell.copy($0) })
        } else {
            StepView(
                content: node.content, level: node.level,
                state: Flow.state(of: node, ticks: snapshot.ticks, current: snapshot.current),
                total: total, readOnly: readOnly, expanded: expanded(node.path),
                onToggle: { model.toggleTick(node.path, in: snapshot.id) },
                onCopy: { model.shell.copy($0) })
        }
    }

    /// A done step's (or done parent's) expansion, by path, in `model.expandedDone[id]`.
    private func expanded(_ path: String) -> Binding<Bool> {
        let id = snapshot.id
        return Binding(
            get: { model.expandedDone[id]?.contains(path) ?? false },
            set: { model.expandedDone[id] = Self.toggled(model.expandedDone[id], path: path, expanded: $0) })
    }
}
