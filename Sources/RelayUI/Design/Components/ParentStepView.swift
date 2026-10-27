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

/// Design/ParentStepView: a step with sub-steps, as one row of the grouped steps list with
/// its sub-steps as rows inside it. It follows StepView's rules: done (every sub-step, and
/// its own question, done) collapses to ✓ and the title; holding the current item it is open;
/// upcoming it shows the title and opens by click; locked it shows a lock and the lock line.
/// The parent tick is derived from its sub-steps; ticking it ticks or unticks them all (the
/// Store leaves locked ones alone). A parent that asks its own question shows it under its
/// text, above the sub-steps; the question is one more item of its count, and its marker is
/// not a tick, unless the parent is optional: then its tick marks the question done
/// unanswered along with the sub-steps. An optional parent shows an "Optional" caption.
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
    /// The parent's lock line when the whole step is locked; nil when it isn't.
    let lockText: String?
    /// Each sub-step's lock line, when locked (after a blocking sub-step); one per entry of `children`.
    let childLockTexts: [String?]
    let onToggleParent: () -> Void
    let onToggleChild: (Int) -> Void
    let onCopy: (String) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(content: StepContent, number: Int, total: Int, children: [StepContent], childPaths: [String],
                childStates: [StepState], readOnly: Bool, expanded: Binding<Bool>,
                childExpanded: @escaping (Int) -> Binding<Bool>, childQuestions: [StepQuestion?] = [],
                question: StepQuestion? = nil, ownState: StepState? = nil, lockText: String? = nil,
                childLockTexts: [String?] = [],
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
        self.lockText = lockText
        self.childLockTexts = childLockTexts
        self.onToggleParent = onToggleParent
        self.onToggleChild = onToggleChild
        self.onCopy = onCopy
    }

    /// Done items (Flow.parentProgress): the sub-steps, plus the parent's own question.
    private var ticked: Int { childStates.filter { $0 == .done }.count + (ownState == .done ? 1 : 0) }
    private var itemTotal: Int { children.count + (ownState == nil ? 0 : 1) }
    private var allDone: Bool { ticked == itemTotal }
    private var holdsCurrent: Bool { childStates.contains(.current) || ownState == .current }
    private var locked: Bool { lockText != nil }
    /// The row's state: done, current (holds the current item) or upcoming.
    private var state: StepState { ParentStepView.rowState(allDone: allDone, holdsCurrent: holdsCurrent) }
    private var isOpen: Bool { StepRow.isOpen(state: state, locked: locked, expanded: expanded.wrappedValue) }
    private var expandable: Bool { StepRow.isExpandable(state: state, locked: locked) }
    /// No parent tick on a parent that asks a required question: Mark All acts on ticks, never
    /// on the answer. An optional parent's question is ticked with its sub-steps.
    private var tickable: Bool { !readOnly && (question == nil || content.optional) && !locked }

    public static func rowState(allDone: Bool, holdsCurrent: Bool) -> StepState {
        allDone ? .done : (holdsCurrent ? .current : .todo)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.stepPart) {
            rowMenu(header)
            if let warning = StepRow.warning(content, state: state, locked: locked) {
                WarningBox(warning).padding(.leading, DS.Space.subIndent)
            }
            if isOpen {
                VStack(alignment: .leading, spacing: DS.Space.stepPart) {
                    StepBody(content: content, level: .top(number), onCopy: onCopy)
                    if let question { QuestionBlock(question).padding(.top, DS.Space.stepPart) }
                    subSteps
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, DS.Space.subIndent)
                .transition(.opacity)
            }
        }
        .padding(.horizontal, DS.Space.groupRowH)
        .padding(.vertical, DS.Space.groupRowV)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityActions {
            if tickable {
                Button(StepAccessibility.parentAction(done: ticked, total: itemTotal)) { toggleParent() }
            }
        }
    }

    private var subSteps: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(children.indices, id: \.self) { i in
                StepView(content: children[i], level: .sub(number, i), state: childStates[i], total: total,
                         readOnly: readOnly, expanded: childExpanded(i),
                         question: childQuestions.indices.contains(i) ? childQuestions[i] : nil,
                         lockText: lockText ?? (childLockTexts.indices.contains(i) ? childLockTexts[i] : nil),
                         onToggle: { onToggleChild(i) }, onCopy: onCopy)
                    .id(childPaths[i])
                    .background(GeometryReader { geometry in
                        Color.clear.preference(key: NodeFramesKey.self,
                                               value: [childPaths[i]: geometry.frame(in: .named(detailScrollSpace))])
                    })
            }
        }
    }

    private var accessibilityLabel: String {
        if let lockText {
            return StepAccessibility.lockedLabel(level: .top(number), action: content.action, lockText: lockText)
        }
        let label = StepAccessibility.optional(
            StepAccessibility.parentLabel(number: number, action: content.action, done: ticked, total: itemTotal),
            content.optional)
        guard let question else { return label }
        return label + ". " + StepAccessibility.question(prompt: question.question.prompt, answer: question.answer)
    }

    @ViewBuilder private var marker: some View {
        if let lockText {
            LockMarker(level: .top(number),
                       label: StepAccessibility.lockedLabel(level: .top(number), action: content.action, lockText: lockText))
        } else if question != nil, !content.optional {
            StepMarker(level: .top(number), state: allDone ? .done : (ownState == .current ? .current : .todo),
                       label: line(content.action))
        } else {
            TickButton(level: .top(number), state: allDone ? .done : (holdsCurrent ? .current : .todo),
                       label: StepAccessibility.optional(line(content.action), content.optional),
                       hint: StepAccessibility.hint(level: .top(number), total: total),
                       value: StepAccessibility.parentValue(done: ticked, total: itemTotal),
                       help: StepAccessibility.parentHelp(done: ticked, total: itemTotal),
                       readOnly: readOnly, action: toggleParent)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.marker) {
            marker
            if expandable {
                Button {
                    withAnimation(DS.motion(DS.Motion.reveal, reduce: reduceMotion)) { expanded.wrappedValue.toggle() }
                } label: {
                    titleRow.contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityValue(TrailingDisclosureStyle.value(expanded: expanded.wrappedValue))
                .accessibilityHint(StepRow.disclosureHint(expanded: expanded.wrappedValue))
            } else {
                titleRow
            }
        }
    }

    private var titleRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.inline) {
            VStack(alignment: .leading, spacing: DS.Space.rowLine) {
                if isOpen, let place = content.place {
                    Text(verbatim: line(place)).font(DS.Font.meta).foregroundStyle(DS.Color.secondary)
                }
                Text(verbatim: line(content.action))
                    .font(state == .current && !locked ? DS.Font.currentAction : DS.Font.body)
                    .foregroundStyle(StepRow.dimmed(state: state, locked: locked) ? DS.Color.secondary : DS.Color.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .alignmentProbe(.topActionText)
                if let lockText {
                    Text(verbatim: line(lockText)).font(DS.Font.caption).foregroundStyle(DS.Color.secondary)
                }
            }
            Spacer(minLength: DS.Space.inline)
            if content.optional { StepRow.optionalCaption }
            if !locked {
                Text(verbatim: "\(ticked) of \(itemTotal)")
                    .font(DS.Font.meta).foregroundStyle(DS.Color.secondary).monospacedDigit()
            }
            if expandable { StepRow.chevron(open: expanded.wrappedValue) }
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
                Button(StepAccessibility.parentContextTitle(done: ticked, total: itemTotal)) { toggleParent() }
            }
        }
    }
}
