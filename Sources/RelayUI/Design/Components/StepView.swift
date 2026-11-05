import RelayCore
import SwiftUI

/// Design/StepView: a leaf node (a step without sub-steps, a sub-step, or verify) as one row
/// of the grouped steps list. The marker sits in the leading column and the title beside it.
/// - done: collapsed to ✓ and the title (and "You chose: …" for a question); a click opens it.
/// - current: open, its detail, link, command, expected output and question inline.
/// - upcoming: the title only; a click opens it.
/// - locked (`lockText`): a lock and "Finish step N first"; it can't be opened, ticked or answered.
/// A blocking step's warning box shows under the title whether the row is open or not.
/// A step that asks a question has a plain marker instead of a tick (only an answer completes it),
/// unless it is optional: then it keeps the tick, and a tick marks it done unanswered.
/// An optional step shows an "Optional" caption at the end of its title row.
/// A required step left (`stepRequired`, owner pick 1) carries a badge on its marker and the
/// required hue behind its row, until it is finished.
/// Report a Problem (`stepReport`, 0.14): an open, actionable, unreported row ends with Report at
/// its bottom right, which opens the report's field right there; a row that can't expand offers
/// it from its context menu; a reported step shows only the report icon.
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
    /// Copies a command; `.refused` when the ask changed under the click.
    let onCopy: (String) -> CopyOutcome
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openURL) private var openURL
    /// The review lock, apart from the blocking-step `locked`.
    @Environment(\.askContentLocked) private var contentLocked
    @Environment(\.stepTag) private var tag
    @Environment(\.stepReport) private var report
    @Environment(\.stepRequired) private var required

    public init(content: StepContent, level: StepLevel, state: StepState, total: Int, readOnly: Bool,
                expanded: Binding<Bool>, question: StepQuestion? = nil, lockText: String? = nil,
                onToggle: @escaping () -> Void, onCopy: @escaping (String) -> CopyOutcome) {
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
    private var showsReport: Bool {
        guard let report else { return false }
        return StepRow.showsReportLink(report, open: isOpen, locked: locked)
    }
    private var reportsFromMenu: Bool {
        guard let report else { return false }
        return StepRow.reportsFromMenu(allowed: report.allowed, actionable: report.actionable, expandable: expandable,
                                       locked: locked)
    }
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
                marker.requiredBadge(required)
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
            reportArea
        }
        .padding(.horizontal, level.isSub ? 0 : DS.Space.groupRowH)
        .padding(.vertical, level.isSub ? DS.Space.subRowV : DS.Space.groupRowV)
        .frame(maxWidth: .infinity, alignment: .leading)
        .requiredRow(required, bleed: level.isSub ? Self.subBleed : EdgeInsets())
    }

    /// The bottom of the row: the open report field, else Report on an expanded row.
    @ViewBuilder private var reportArea: some View {
        if let report, StepRow.showsReportField(report) {
            InlineReportField(title: ProblemReport.composerTitle(label: level.label), slot: report)
                .padding(.leading, DS.Space.subIndent)
                .padding(.bottom, DS.Space.stepPart)
        } else if showsReport, let report {
            StepReportLink(action: report.onReport)
                .padding(.leading, DS.Space.subIndent)
        }
    }

    /// A sub-step row has no side padding of its own: its hue reaches past it.
    static let subBleed = EdgeInsets(top: 0, leading: DS.Space.requiredBleed, bottom: 0,
                                     trailing: DS.Space.requiredBleed)

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
            if let tag { StepTag(tag) }
            if report?.reported == true { ReportedMark() }
            if content.optional && !content.optionalByParent { StepRow.optionalCaption }
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
            LockMarker(level: level, label: StepAccessibility.required(
                StepAccessibility.lockedLabel(level: level, action: content.action, lockText: lockText), required))
        } else if let question, !content.optional {
            StepMarker(level: level, state: state,
                       label: StepAccessibility.required(
                           StepAccessibility.questionLabel(action: content.action, prompt: question.question.prompt,
                                                           answer: question.answer), required))
        } else {
            TickButton(level: level, state: state, label: tickLabel,
                       hint: StepAccessibility.hint(level: level, total: total), value: StepAccessibility.tickValue(state),
                       help: StepAccessibility.help(state), readOnly: readOnly, action: toggle)
        }
    }

    /// The tick's label: the action (and an optional question's prompt and answer), then
    /// ", optional", or ", required" while a required step is left.
    private var tickLabel: String {
        let label = question.map {
            StepAccessibility.questionLabel(action: content.action, prompt: $0.question.prompt, answer: $0.answer)
        } ?? line(content.action)
        return StepAccessibility.required(StepAccessibility.optional(label, content.optional), required)
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
        let tickable = !readOnly && (question == nil || content.optional) && !locked && !contentLocked
        let offered = StepRow.actions(content, locked: locked, contentLocked: contentLocked)
        let withActions = view.accessibilityActions {
            if tickable { Button(StepAccessibility.markAction(state)) { toggle() } }
            if offered.contains(StepRow.copyAction), let code = content.code {
                Button(StepRow.copyAction) {
                    let outcome = onCopy(Sanitize.copyText(code))
                    AccessibilityNotification.Announcement(CodeBlock.announcement(outcome)).post()
                }
            }
            if offered.contains(StepRow.openAction), let url = webURL { Button(StepRow.openAction) { openURL(url) } }
        }
        if !tickable && !reportsFromMenu {
            withActions
        } else {
            withActions.contextMenu {
                if tickable { Button(StepAccessibility.contextTitle(state)) { toggle() } }
                if reportsFromMenu, let report { Button(ProblemReport.menuTitle) { report.onReport() } }
            }
        }
    }
}

/// The row rules both step views share; static so tests can pin them.
public enum StepRow {
    public static let copyAction = "Copy command"
    public static let openAction = "Open link"

    /// The VoiceOver actions that copy or open: none on a step locked behind a blocking one
    /// (`locked`), and none while the ask's content is locked for review (`contentLocked`).
    public static func actions(_ content: StepContent, locked: Bool, contentLocked: Bool) -> [String] {
        guard !locked, AskContentLock.allowsActions(locked: contentLocked) else { return [] }
        var names: [String] = []
        if content.code != nil { names.append(copyAction) }
        if let raw = content.url, LinkDisplay.isWeb(raw), URL(string: raw) != nil { names.append(openAction) }
        return names
    }

    /// Report shows at the bottom right of an open, actionable row (code or a tick) on an ask
    /// that takes reports, until it is reported; never while a report field is open anywhere in
    /// the ask (a second link would drop the note being typed), on hover, a collapsed row, a
    /// locked one, a closed ask or This Mac.
    public static func showsReportLink(_ slot: StepReportSlot, open: Bool, locked: Bool) -> Bool {
        slot.allowed && slot.actionable && open && !locked && !slot.reported && !slot.targeted && !slot.fieldOpen
    }

    /// The inline field shows while its row is the report's target, even on a collapsed row (the
    /// queue row's Report a Problem… can pick one).
    public static func showsReportField(_ slot: StepReportSlot) -> Bool {
        slot.allowed && slot.targeted
    }

    /// A row that can't expand gets Report a Problem… from its context menu.
    public static func reportsFromMenu(allowed: Bool, actionable: Bool, expandable: Bool, locked: Bool) -> Bool {
        allowed && actionable && !expandable && !locked
    }

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
        // Explicit cautions remain visible when completed instructions are revisited.
        if let warning = content.warning, !warning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return warning
        }
        guard !locked, state != .done else { return nil }
        return content.warningText
    }

    /// Anything to show under the title once open (a question is checked by the caller).
    public static func hasBody(_ content: StepContent) -> Bool {
        content.detail != nil || content.url != nil || content.code != nil || content.expect != nil
            || content.file != nil
    }

    /// "Optional" at the end of an optional step's title row. VoiceOver hears it on the marker
    /// (`StepAccessibility.optional`), so the caption itself is hidden from it.
    static var optionalCaption: some View {
        Text(verbatim: StepAccessibility.optionalCaption)
            .font(DS.Font.caption)
            .foregroundStyle(DS.Color.secondary)
            .accessibilityHidden(true)
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
