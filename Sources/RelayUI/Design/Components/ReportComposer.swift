import RelayCore
import SwiftUI

/// Design/ReportComposer: Report a Problem's composer, docked above the detail's action bar
/// (0.12, pick 3 B, report mode only). "Problem with step N" with a "?", a one-line field
/// ("What went wrong?") and Send. Return sends, Esc cancels, the counter shows from 250
/// characters, and Send is off outside 1 to 300. Without an approved owner key the button is
/// Set Up Owner Key…: the note is held and sent once the key is approved.
public struct ReportComposer: View {
    let title: String
    let state: ReportBoxState
    let keyReady: Bool
    let onSend: (String) -> Void
    let onCancel: () -> Void
    @State private var text: String
    @FocusState private var focused: Bool

    public init(title: String, state: ReportBoxState, keyReady: Bool, text: String = "",
                onSend: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        self.title = title
        self.state = state
        self.keyReady = keyReady
        self.onSend = onSend
        self.onCancel = onCancel
        _text = State(initialValue: text)
    }

    /// Send (or Set Up Owner Key…) is on for 1 to 300 characters, while nothing is in flight or held.
    public static func canSend(_ text: String, state: ReportBoxState) -> Bool {
        ProblemReport.canSend(text) && state != .sending && state != .held
    }

    /// The line under the field: held, or why the Pond refused the note.
    public static func caption(_ state: ReportBoxState) -> String? {
        switch state {
        case .held: return ProblemReport.heldCaption
        case .failed(let reason): return line(reason)
        case .idle, .sending: return nil
        }
    }

    public var body: some View {
        VStack(spacing: 0) {
            Divider()
            VStack(alignment: .leading, spacing: DS.Space.rowLine) {
                HStack(alignment: .firstTextBaseline, spacing: DS.Space.inline) {
                    Label(title, systemImage: DS.Symbol.report)
                        .font(DS.Font.caption.weight(.semibold))
                    HelpButton(rowLabel: ProblemReport.menuTitle, text: ProblemReport.help)
                        .controlSize(DS.Control.inline)
                    Spacer(minLength: DS.Space.inline)
                    if ProblemReport.showsCounter(text) {
                        Text(ProblemReport.counter(text))
                            .font(DS.Font.meta)
                            .monospacedDigit()
                            .foregroundStyle(ProblemReport.canSend(text) ? DS.Color.secondary : DS.Color.errorText)
                    }
                    IconButton(DS.Symbol.clearFilter, label: "Cancel the report", help: "Cancel (Esc)", action: onCancel)
                }
                HStack(alignment: .firstTextBaseline, spacing: DS.Space.inline) {
                    // The owner's note is not sanitized; the Store cleans line breaks before sending.
                    TextField(ProblemReport.placeholder, text: $text, prompt: Text(ProblemReport.placeholder))
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                        .focused($focused)
                        .disabled(state == .held)
                        .onSubmit { send() }
                        .onExitCommand { onCancel() }
                        .accessibilityLabel(title)
                    sendButton
                }
                if let caption = Self.caption(state) {
                    Text(caption)
                        .font(DS.Font.caption)
                        .foregroundStyle(state == .held ? DS.Color.secondary : DS.Color.errorText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .controlSize(DS.Control.form)
            .padding(.horizontal, DS.Space.gutter)
            .padding(.vertical, DS.Space.barStackV)
            .background(DS.Color.bar)
        }
        .onAppear { focused = true }
    }

    @ViewBuilder private var sendButton: some View {
        if state == .sending {
            Button {} label: {
                ProgressView().controlSize(DS.Control.inline).accessibilityLabel("Sending")
            }
            .disabled(true)
        } else {
            Button(keyReady ? "Send" : ProblemReport.setUpKeyTitle) { send() }
                .disabled(!Self.canSend(text, state: state))
                .help(keyReady ? "Send (Return)" : ProblemReport.notEnrolled)
        }
    }

    private func send() {
        guard Self.canSend(text, state: state) else { return }
        onSend(text)
    }
}

/// The open row's trailing Report: bordered, inline size, with the report symbol.
struct ReportButton: View {
    let action: @MainActor () -> Void

    var body: some View {
        Button { action() } label: {
            Label(ProblemReport.buttonTitle, systemImage: DS.Symbol.report)
        }
        .buttonStyle(.bordered)
        .controlSize(DS.Control.inline)
        .fixedSize()
        .help(ProblemReport.buttonHelp)
    }
}

/// A reported step: only the filled icon, with a tooltip and VoiceOver's label; no caption.
struct ReportedMark: View {
    var body: some View {
        Image(systemName: DS.Symbol.reported)
            .imageScale(.small)
            .foregroundStyle(DS.Color.warnText)
            .help(ProblemReport.reportedHelp)
            .accessibilityElement()
            .accessibilityLabel(ProblemReport.reportedLabel)
    }
}

/// The step the composer reports on: a light accent fill and outline, inset in its row.
struct ReportTargetHighlight: View {
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: DS.Metric.groupRadius - DS.Metric.targetInset, style: .continuous)
        shape.fill(DS.Color.targetFill)
            .overlay(shape.strokeBorder(DS.Color.targetStroke, lineWidth: DS.Metric.targetStroke))
            .padding(DS.Metric.targetInset)
            .accessibilityHidden(true)
    }
}
