import RelayCore
import SwiftUI

/// The detail ScrollView's coordinate space; node frames are reported in it.
let detailScrollSpace = "relay.detail.scroll"

/// Each step node's frame, by path, in `detailScrollSpace`: top-level nodes (DetailSteps) and sub-steps (ParentStepView).
struct NodeFramesKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

/// Design/ParentStepView: a step with sub-steps. The parent tick is derived from
/// its sub-steps; ticking it ticks or unticks them all. Once every sub-step is done the parent
/// collapses into a disclosure. A parent that asks its own question shows it under its text,
/// above the sub-steps; the question is one more item of its count, and its marker is not a
/// tick (only an answer completes the question; the sub-steps keep their own ticks).
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
    /// Each sub-step's question block, when it asks one; one per entry of `children`.
    let childQuestions: [StepQuestion?]
    let question: StepQuestion?
    /// The parent's own question's state (Flow.state(of: parent)); nil when it asks none.
    let ownState: StepState?
    let onToggleParent: () -> Void
    let onToggleChild: (Int) -> Void
    let onCopy: (String) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(content: StepContent, number: Int, total: Int, children: [StepContent], childPaths: [String],
                childStates: [StepState], readOnly: Bool, expanded: Binding<Bool>,
                childExpanded: @escaping (Int) -> Binding<Bool>, childQuestions: [StepQuestion?] = [],
                question: StepQuestion? = nil, ownState: StepState? = nil,
                onToggleParent: @escaping () -> Void,
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
        self.childQuestions = childQuestions
        self.question = question
        self.ownState = question == nil ? nil : ownState
        self.onToggleParent = onToggleParent
        self.onToggleChild = onToggleChild
        self.onCopy = onCopy
    }

    /// Done items (Flow.parentProgress): the sub-steps, plus the parent's own question.
    private var ticked: Int { childStates.filter { $0 == .done }.count + (ownState == .done ? 1 : 0) }
    private var itemTotal: Int { children.count + (ownState == nil ? 0 : 1) }
    private var allDone: Bool { ticked == itemTotal }
    private var holdsCurrent: Bool { childStates.contains(.current) || ownState == .current }
    /// No parent tick on a parent that asks: Mark All acts on ticks, never on the question.
    private var tickable: Bool { !readOnly && question == nil }

    public var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.subStep) {
            if allDone { rowMenu(doneRow) } else { rowMenu(openRow) }
            if !allDone || expanded.wrappedValue {
                VStack(alignment: .leading, spacing: DS.Space.subStep) {
                    ForEach(children.indices, id: \.self) { i in
                        StepView(content: children[i], level: .sub(number, i), state: childStates[i], total: total,
                                 readOnly: readOnly, expanded: childExpanded(i),
                                 question: childQuestions.indices.contains(i) ? childQuestions[i] : nil,
                                 onToggle: { onToggleChild(i) }, onCopy: onCopy)
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
        .accessibilityLabel(accessibilityLabel)
        .accessibilityActions {
            if tickable {
                Button(StepAccessibility.parentAction(done: ticked, total: itemTotal)) { toggleParent() }
            }
        }
    }

    private var accessibilityLabel: String {
        let label = StepAccessibility.parentLabel(number: number, action: content.action, done: ticked, total: itemTotal)
        guard let question else { return label }
        return label + ". " + StepAccessibility.question(prompt: question.question.prompt, answer: question.answer)
    }

    @ViewBuilder private var tick: some View {
        if question != nil {
            StepMarker(level: .top(number), state: allDone ? .done : (ownState == .current ? .current : .todo),
                       label: line(content.action))
        } else {
            TickButton(level: .top(number), state: allDone ? .done : .todo, label: line(content.action),
                       hint: StepAccessibility.hint(level: .top(number), total: total),
                       value: StepAccessibility.parentValue(done: ticked, total: children.count),
                       help: StepAccessibility.parentHelp(done: ticked, total: children.count),
                       readOnly: readOnly, action: toggleParent)
        }
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
                    Text(verbatim: "\(ticked) of \(itemTotal)")
                        .font(DS.Font.meta).foregroundStyle(DS.Color.secondary).monospacedDigit()
                }
                StepBody(content: content, level: .top(number), onCopy: onCopy)
                if let question { QuestionBlock(question) }
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
                    if let question { QuestionBlock(question) }
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
        if !tickable {
            row
        } else {
            row.contextMenu {
                Button(StepAccessibility.parentContextTitle(done: ticked, total: children.count)) { toggleParent() }
            }
        }
    }
}
