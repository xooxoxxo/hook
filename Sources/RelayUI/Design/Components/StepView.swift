import RelayCore
import SwiftUI

/// Design/StepView: a leaf node (a step without sub-steps, a sub-step, or verify) as one row
/// of the grouped steps list. The marker sits in the leading column and the title beside it.
/// - done: collapsed to ✓ and the title (and "You chose: …" for a question); a click opens it.
/// - current: open, its detail, link, command, expected output and question inline.
/// - upcoming: the title only; a click opens it.
/// - locked (`lockText`): a lock and "Finish step N first"; it can't be opened, ticked or answered.
/// A blocking step's warning box shows under the title whether the row is open or not.
/// A step that asks a question has a plain marker instead of a tick (only an answer completes it).
public struct StepView: View {
    let content: StepContent
    let level: StepLevel
    let state: StepState
    let total: Int
    let readOnly: Bool
    let expanded: Binding<Bool>
    let question: StepQuestion?
    /// "Finish step 3 first" when the step is locked; nil when it isn't.
    let lockText: String?
    let onToggle: () -> Void
    let onCopy: (String) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openURL) private var openURL

    public init(content: StepContent, level: StepLevel, state: StepState, total: Int, readOnly: Bool,
                expanded: Binding<Bool>, question: StepQuestion? = nil, lockText: String? = nil,
                onToggle: @escaping () -> Void, onCopy: @escaping (String) -> Void) {
        self.content = content
        self.level = level
        self.state = state
        self.total = total
        self.readOnly = readOnly
        self.expanded = expanded
        self.question = question
        self.lockText = lockText
        self.onToggle = onToggle
        self.onCopy = onCopy
    }

    private var locked: Bool { lockText != nil }
    private var isOpen: Bool { StepRow.isOpen(state: state, locked: locked, expanded: expanded.wrappedValue) }
    /// Only a row with something to reveal gets a disclosure.
    private var expandable: Bool {
        StepRow.isExpandable(state: state, locked: locked)
            && (StepRow.hasBody(content) || question != nil || placeText != nil)
    }

    public var body: some View {
        actions(row)
    }

    private var row: some View {
        VStack(alignment: .leading, spacing: DS.Space.stepPart) {
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.marker) {
                marker
                titleArea
            }
            if let warning = StepRow.warning(content, state: state, locked: locked) {
                WarningBox(warning).padding(.leading, DS.Space.subIndent)
            }
            if isOpen, StepRow.hasBody(content) || question != nil {
                VStack(alignment: .leading, spacing: DS.Space.stepPart) {
                    StepBody(content: content, level: level, onCopy: onCopy)
                    if let question { QuestionBlock(question).padding(.top, DS.Space.stepPart) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, DS.Space.subIndent)
                .padding(.bottom, DS.Space.stepPart)
                .transition(.opacity)
            }
        }
        .padding(.horizontal, level.isSub ? 0 : DS.Space.groupRowH)
        .padding(.vertical, level.isSub ? DS.Space.subRowV : DS.Space.groupRowV)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var placeText: String? { StepAccessibility.placeText(level: level, place: content.place) }

    /// The title column: the place (when open), the action, and the collapsed row's subtitle.
    @ViewBuilder private var titleArea: some View {
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

    private var titleRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.inline) {
            VStack(alignment: .leading, spacing: DS.Space.rowLine) {
                if isOpen, let place = placeText {
                    Text(verbatim: place).font(DS.Font.meta).foregroundStyle(DS.Color.secondary)
                }
                actionText(state == .current && !locked ? DS.Font.currentAction : DS.Font.body)
                    .foregroundStyle(StepRow.dimmed(state: state, locked: locked) ? DS.Color.secondary : DS.Color.primary)
                    .fixedSize(horizontal: false, vertical: true)
                if let subtitle {
                    Text(verbatim: line(subtitle))
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Color.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            Spacer(minLength: DS.Space.inline)
            if expandable { StepRow.chevron(open: expanded.wrappedValue) }
        }
    }

    /// Locked: the lock line. A collapsed question: "Not sent" for a draft, else its answer.
    private var subtitle: String? {
        if let lockText { return lockText }
        if !isOpen, let question {
            if !question.readOnly, question.isUnsent { return "Not sent" }
            if let answer = question.answer { return AnswerDrafts.answeredText(answer) }
        }
        return nil
    }

    /// The action, prefixed for a sub-step with its label ("2a  …") in meta, secondary.
    private func actionText(_ font: Font) -> some View {
        let action = Text(verbatim: line(content.action)).font(font)
        let text = level.isSub
            ? Text(verbatim: level.label + "  ").font(DS.Font.meta).foregroundStyle(DS.Color.secondary).monospacedDigit() + action
            : action
        return text.alignmentProbe(level.isSub ? .subLabelText : .topActionText)
    }

    @ViewBuilder private var marker: some View {
        if let lockText {
            LockMarker(level: level, label: StepAccessibility.lockedLabel(level: level, action: content.action,
                                                                           lockText: lockText))
        } else if let question {
            StepMarker(level: level, state: state,
                       label: StepAccessibility.questionLabel(action: content.action, prompt: question.question.prompt,
                                                              answer: question.answer))
        } else {
            TickButton(level: level, state: state, label: line(content.action),
                       hint: StepAccessibility.hint(level: level, total: total), value: StepAccessibility.tickValue(state),
                       help: StepAccessibility.help(state), readOnly: readOnly, action: toggle)
        }
    }

    private func toggle() {
        withAnimation(DS.motion(DS.Motion.step, reduce: reduceMotion)) { onToggle() }
    }

    private var webURL: URL? {
        guard let raw = content.url, LinkDisplay.isWeb(raw) else { return nil }
        return URL(string: raw)
    }

    /// VoiceOver's custom actions and the context menu, where they apply; none on a locked step.
    @ViewBuilder private func actions(_ view: some View) -> some View {
        let tickable = !readOnly && question == nil && !locked
        let withActions = view.accessibilityActions {
            if tickable { Button(StepAccessibility.markAction(state)) { toggle() } }
            if !locked, let code = content.code { Button("Copy command") { onCopy(Sanitize.copyText(code)) } }
            if !locked, let url = webURL { Button("Open link") { openURL(url) } }
        }
        if !tickable {
            withActions
        } else {
            withActions.contextMenu { Button(StepAccessibility.contextTitle(state)) { toggle() } }
        }
    }
}

/// The row rules both step views share; static so tests can pin them.
public enum StepRow {
    /// The current step is always open; a locked one never; done and upcoming ones when opened by hand.
    public static func isOpen(state: StepState, locked: Bool, expanded: Bool) -> Bool {
        guard !locked else { return false }
        return state == .current || expanded
    }

    /// Done and upcoming rows open and close by click; the current and locked ones don't.
    public static func isExpandable(state: StepState, locked: Bool) -> Bool {
        !locked && state != .current
    }

    /// Done and locked titles are secondary.
    public static func dimmed(state: StepState, locked: Bool) -> Bool { locked || state == .done }

    /// The warning box text while the blocking step is unfinished and not itself locked.
    public static func warning(_ content: StepContent, state: StepState, locked: Bool) -> String? {
        guard !locked, state != .done else { return nil }
        return content.warningText
    }

    /// Anything to show under the title once open (a question is checked by the caller).
    public static func hasBody(_ content: StepContent) -> Bool {
        content.detail != nil || content.url != nil || content.code != nil || content.expect != nil
    }

    public static func disclosureHint(expanded: Bool) -> String {
        expanded ? "Hides the step's details" : "Shows the step's details"
    }

    static func chevron(open: Bool) -> some View {
        Image(systemName: open ? DS.Symbol.disclosureOpen : DS.Symbol.disclosureClosed)
            .imageScale(.small)
            .foregroundStyle(DS.Color.secondary)
            .accessibilityHidden(true)
    }
}

/// Design/LockMarker: a locked step's marker, in the tick's column. Not a button.
public struct LockMarker: View {
    let level: StepLevel
    let label: String

    public init(level: StepLevel, label: String) {
        self.level = level
        self.label = label
    }

    public var body: some View {
        Image(systemName: DS.Symbol.locked)
            .imageScale(level.isSub ? .small : .medium)
            .foregroundStyle(DS.Color.secondary)
            .frame(minWidth: DS.Metric.hit, minHeight: DS.Metric.hit)
            .frame(width: DS.Metric.hit)
            .accessibilityElement()
            .accessibilityLabel(label)
            .alignmentProbe(level.isSub ? .subMarker : .topMarker)
    }
}
