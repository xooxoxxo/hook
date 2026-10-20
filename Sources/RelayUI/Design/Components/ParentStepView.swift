import RelayCore
import SwiftUI

/// The detail ScrollView's coordinate space; node frames are reported in it.
let detailScrollSpace = "relay.detail.scroll"

/// Each step node's frame, by path, in `detailScrollSpace`: top-level nodes (DetailView) and sub-steps (ParentStepView).
struct NodeFramesKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

/// Design/ParentStepView: a step with sub-steps. The parent tick is derived from
/// its sub-steps; ticking it ticks or unticks them all. Once every sub-step is done the parent
/// collapses into a disclosure.
public struct ParentStepView: View {
    let content: StepContent
    let number: Int
    let total: Int
    let children: [StepContent]
    /// The sub-steps' paths ("3.1", "3.2"), one per entry of `children`.
    let childPaths: [String]
    let childStates: [StepState]
    let readOnly: Bool
    let expanded: Binding<Bool>
    let childExpanded: (Int) -> Binding<Bool>
    let onToggleParent: () -> Void
    let onToggleChild: (Int) -> Void
    let onCopy: (String) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(content: StepContent, number: Int, total: Int, children: [StepContent], childPaths: [String],
                childStates: [StepState], readOnly: Bool, expanded: Binding<Bool>,
                childExpanded: @escaping (Int) -> Binding<Bool>, onToggleParent: @escaping () -> Void,
                onToggleChild: @escaping (Int) -> Void, onCopy: @escaping (String) -> Void) {
        self.content = content
        self.number = number
        self.total = total
        self.children = children
        self.childPaths = childPaths
        self.childStates = childStates
        self.readOnly = readOnly
        self.expanded = expanded
        self.childExpanded = childExpanded
        self.onToggleParent = onToggleParent
        self.onToggleChild = onToggleChild
        self.onCopy = onCopy
    }

    private var ticked: Int { childStates.filter { $0 == .done }.count }
    private var allDone: Bool { ticked == children.count }
    private var holdsCurrent: Bool { childStates.contains(.current) }

    public var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.subStep) {
            if allDone { rowMenu(doneRow) } else { rowMenu(openRow) }
            if !allDone || expanded.wrappedValue {
                VStack(alignment: .leading, spacing: DS.Space.subStep) {
                    ForEach(children.indices, id: \.self) { i in
                        StepView(content: children[i], level: .sub(number, i), state: childStates[i], total: total,
                                 readOnly: readOnly, expanded: childExpanded(i), onToggle: { onToggleChild(i) }, onCopy: onCopy)
                            .id(childPaths[i])
                            .background(GeometryReader { geometry in
                                Color.clear.preference(key: NodeFramesKey.self,
                                                       value: [childPaths[i]: geometry.frame(in: .named(detailScrollSpace))])
                            })
                    }
                }
                .padding(.leading, DS.Space.subIndent)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(StepAccessibility.parentLabel(number: number, action: content.action,
                                                          done: ticked, total: children.count))
        .accessibilityActions {
            if !readOnly {
                Button(StepAccessibility.parentAction(done: ticked, total: children.count)) { toggleParent() }
            }
        }
    }

    private var tick: some View {
        TickButton(level: .top(number), state: allDone ? .done : .todo, label: line(content.action),
                   hint: StepAccessibility.hint(level: .top(number), total: total),
                   value: StepAccessibility.parentValue(done: ticked, total: children.count),
                   help: StepAccessibility.parentHelp(done: ticked, total: children.count),
                   readOnly: readOnly, action: toggleParent)
    }

    @ViewBuilder private var placeText: some View {
        if let place = content.place {
            Text(verbatim: line(place)).font(DS.Font.meta).foregroundStyle(DS.Color.secondary)
        }
    }

    private var openRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.marker) {
            tick
            VStack(alignment: .leading, spacing: DS.Space.stepPart) {
                placeText
                HStack(alignment: .firstTextBaseline, spacing: DS.Space.inline) {
                    Text(verbatim: line(content.action))
                        .font(holdsCurrent ? DS.Font.currentAction : DS.Font.body)
                        .fixedSize(horizontal: false, vertical: true)
                        .alignmentProbe(.topActionText)
                    Spacer(minLength: DS.Space.inline)
                    Text(verbatim: "\(ticked) of \(children.count)")
                        .font(DS.Font.meta).foregroundStyle(DS.Color.secondary).monospacedDigit()
                }
                StepBody(content: content, level: .top(number), onCopy: onCopy)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var doneRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.marker) {
            tick
            DisclosureGroup(isExpanded: expanded) {
                VStack(alignment: .leading, spacing: DS.Space.stepPart) {
                    placeText
                    StepBody(content: content, level: .top(number), onCopy: onCopy)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, DS.Space.stepPart)
            } label: {
                Text(verbatim: line(content.action)).foregroundStyle(DS.Color.secondary).lineLimit(1)
                    .alignmentProbe(.topActionText)
            }
            .disclosureGroupStyle(.trailing)
        }
    }

    private func toggleParent() {
        withAnimation(DS.motion(DS.Motion.step, reduce: reduceMotion)) { onToggleParent() }
    }

    /// The parent's own row gets "Mark All as Done" / "Mark All as Not Done"; sub-steps keep their own menu.
    @ViewBuilder private func rowMenu(_ row: some View) -> some View {
        if readOnly {
            row
        } else {
            row.contextMenu {
                Button(StepAccessibility.parentContextTitle(done: ticked, total: children.count)) { toggleParent() }
            }
        }
    }
}
