import RelayCore
import SwiftUI

/// Design/TickButton: a step's marker, an `IconButton` that ticks or unticks it.
/// The marker's symbol and colour come from `DS.Symbol.marker` and `DS.Color.marker`.
/// `label` is already sanitized (the caller passes `line(action)`).
public struct TickButton: View {
    let level: StepLevel
    let state: StepState
    let label: String
    let hint: String
    let value: String
    let help: String
    let readOnly: Bool
    let action: () -> Void

    public init(level: StepLevel, state: StepState, label: String, hint: String, value: String, help: String,
                readOnly: Bool, action: @escaping () -> Void) {
        self.level = level
        self.state = state
        self.label = label
        self.hint = hint
        self.value = value
        self.help = help
        self.readOnly = readOnly
        self.action = action
    }

    public static func scale(for level: StepLevel) -> Image.Scale { level.isSub ? .medium : .large }

    public var body: some View {
        IconButton(DS.Symbol.marker(level: level, state: state), label: label, help: help,
                   tint: DS.Color.marker(state), scale: Self.scale(for: level), action: action)
            .accessibilityAddTraits(.isToggle)
            .accessibilityValue(value)
            .accessibilityHint(hint)
            .disabled(readOnly)
            // One marker column per level: a wider glyph (verify's seal at a large text size) must not push its text off the edge.
            .frame(width: DS.Metric.hit)
            .alignmentProbe(level.isSub ? .subMarker : .topMarker)
    }
}

/// Design/StepMarker: a question step's marker. It looks like `TickButton`'s and sits in the
/// same column, but it is not a button: only an answer completes a question (Flow.isDone).
public struct StepMarker: View {
    let level: StepLevel
    let state: StepState
    let label: String

    public init(level: StepLevel, state: StepState, label: String) {
        self.level = level
        self.state = state
        self.label = label
    }

    public var body: some View {
        Image(systemName: DS.Symbol.marker(level: level, state: state))
            .imageScale(TickButton.scale(for: level))
            .foregroundStyle(DS.Color.marker(state))
            .frame(minWidth: DS.Metric.hit, minHeight: DS.Metric.hit)
            .frame(width: DS.Metric.hit)
            .accessibilityElement()
            .accessibilityLabel(label)
            .alignmentProbe(level.isSub ? .subMarker : .topMarker)
    }
}
