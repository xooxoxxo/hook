import RelayCore
import SwiftUI

/// Design/StepView (design §3.2, §4.4): a leaf node, that is a step without sub-steps, a sub-step,
/// or verify. Todo and current show the whole column; done collapses into a disclosure.
public struct StepView: View {
    let content: StepContent
    let level: StepLevel
    let state: StepState
    let total: Int
    let readOnly: Bool
    let expanded: Binding<Bool>
    let onToggle: () -> Void
    let onCopy: (String) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openURL) private var openURL

    public init(content: StepContent, level: StepLevel, state: StepState, total: Int, readOnly: Bool,
                expanded: Binding<Bool>, onToggle: @escaping () -> Void, onCopy: @escaping (String) -> Void) {
        self.content = content
        self.level = level
        self.state = state
        self.total = total
        self.readOnly = readOnly
        self.expanded = expanded
        self.onToggle = onToggle
        self.onCopy = onCopy
    }

    public var body: some View {
        actions(states)
    }

    @ViewBuilder private var states: some View {
        switch state {
        case .done:
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.marker) {
                tick
                DisclosureGroup(isExpanded: expanded) {
                    VStack(alignment: .leading, spacing: DS.Space.stepPart) {
                        if let place = placeText { Text(verbatim: place).font(DS.Font.meta).foregroundStyle(DS.Color.secondary) }
                        StepBody(content: content, level: level, onCopy: onCopy)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, DS.Space.stepPart)
                } label: {
                    actionText(DS.Font.body).foregroundStyle(DS.Color.secondary).lineLimit(1)
                }
                .disclosureGroupStyle(.trailing)
            }
        case .current:
            // The box bleeds out by currentBleed so the marker and text stay on the column grid.
            GroupBox {
                column(actionFont: DS.Font.currentAction)
                    .padding(DS.Space.currentStep)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, -DS.Space.currentBleed)
            .accessibilityValue("Current step")
        case .todo:
            column(actionFont: DS.Font.body)
        }
    }

    private var placeText: String? { StepAccessibility.placeText(level: level, place: content.place) }

    /// The action, prefixed for a sub-step with its label ("2a  …") in meta, secondary.
    private func actionText(_ font: Font) -> some View {
        let action = Text(verbatim: line(content.action)).font(font)
        let text = level.isSub
            ? Text(verbatim: level.label + "  ").font(DS.Font.meta).foregroundStyle(DS.Color.secondary).monospacedDigit() + action
            : action
        return text.alignmentProbe(level.isSub ? .subLabelText : .topActionText)
    }

    private var tick: some View {
        TickButton(level: level, state: state, label: line(content.action),
                   hint: StepAccessibility.hint(level: level, total: total), value: StepAccessibility.value(state),
                   help: StepAccessibility.help(state), readOnly: readOnly, action: toggle)
    }

    private func column(actionFont: Font) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.marker) {
            tick
            VStack(alignment: .leading, spacing: DS.Space.stepPart) {
                if let place = placeText {
                    Text(verbatim: place).font(DS.Font.meta).foregroundStyle(DS.Color.secondary)
                }
                actionText(actionFont)
                    .fixedSize(horizontal: false, vertical: true)
                StepBody(content: content, level: level, onCopy: onCopy)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func toggle() {
        withAnimation(DS.motion(DS.Motion.step, reduce: reduceMotion)) { onToggle() }
    }

    private var webURL: URL? {
        guard let raw = content.url, LinkDisplay.isWeb(raw) else { return nil }
        return URL(string: raw)
    }

    /// VoiceOver's custom actions and the context menu, where they apply (spec §4.4 Ticking, §4.14).
    @ViewBuilder private func actions(_ view: some View) -> some View {
        let withActions = view.accessibilityActions {
            if !readOnly { Button(StepAccessibility.markAction(state)) { toggle() } }
            if let code = content.code { Button("Copy command") { onCopy(Sanitize.copyText(code)) } }
            if let url = webURL { Button("Open link") { openURL(url) } }
        }
        if readOnly {
            withActions
        } else {
            withActions.contextMenu { Button(StepAccessibility.contextTitle(state)) { toggle() } }
        }
    }
}
