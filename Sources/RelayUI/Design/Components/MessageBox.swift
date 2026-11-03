import RelayCore
import SwiftUI

/// Design/MessageBox: the Messages section's multi-line field (Return adds a line; ⌘Return
/// sends, through the panel's key router, so it never triggers Done), its caption, the
/// counter from 900 characters, and Send. A refusal shows its reason in place of the caption.
public struct MessageBox: View {
    let text: Binding<String>
    let state: MessageBoxState
    let isFocused: FocusState<Bool>.Binding
    let onSend: () -> Void

    public init(text: Binding<String>, state: MessageBoxState, isFocused: FocusState<Bool>.Binding,
                onSend: @escaping () -> Void) {
        self.text = text
        self.state = state
        self.isFocused = isFocused
        self.onSend = onSend
    }

    public static func canSend(_ text: String, state: MessageBoxState) -> Bool {
        MessageText.canSend(text) && state != .sending
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.inline) {
            field
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.inline) {
                caption
                Spacer(minLength: DS.Space.inline)
                if MessageText.showsCounter(text.wrappedValue) {
                    Text(MessageText.counter(text.wrappedValue))
                        .font(DS.Font.meta)
                        .monospacedDigit()
                        .foregroundStyle(MessageText.canSend(text.wrappedValue) ? DS.Color.secondary : DS.Color.errorText)
                }
                sendButton
            }
            .controlSize(DS.Control.form)
        }
    }

    /// A TextEditor drawn as the stock rounded field, with the prompt while empty.
    private var field: some View {
        let shape = RoundedRectangle(cornerRadius: DS.Metric.messageFieldRadius, style: .continuous)
        return ZStack(alignment: .topLeading) {
            // The owner's text is not sanitized: it goes as typed.
            TextEditor(text: text)
                .font(DS.Font.body)
                .scrollContentBackground(.hidden)
                .focused(isFocused)
                .accessibilityLabel(MessageText.placeholder)
            if text.wrappedValue.isEmpty {
                Text(MessageText.placeholder)
                    .font(DS.Font.body)
                    .foregroundStyle(DS.Color.tertiary)
                    .padding(.leading, DS.Metric.messageFieldInset + 1)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .padding(DS.Metric.messageFieldInset)
        .frame(height: DS.Metric.messageField)
        .background(DS.Color.fieldFill, in: shape)
        .overlay(shape.strokeBorder(DS.Color.fieldStroke, lineWidth: DS.Metric.messageFieldStroke))
        .disabled(state == .sending)
    }

    @ViewBuilder private var caption: some View {
        if case .failed(let reason) = state {
            Text(line(reason))
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.errorText)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text(MessageText.caption)
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.secondary)
        }
    }

    @ViewBuilder private var sendButton: some View {
        if state == .sending {
            Button {} label: {
                ProgressView().controlSize(DS.Control.inline).accessibilityLabel("Sending")
            }
            .disabled(true)
        } else {
            Button("Send", action: onSend)
                .disabled(!Self.canSend(text.wrappedValue, state: state))
                .help("Send (⌘Return)")
        }
    }
}
