import RelayCore
import SwiftUI

public enum ReplyBoxState: Equatable, Sendable { case idle, sending, sent(at: String), failed(reason: String) }

/// Design/ReplyBox: the ask's reply prompt, a growing field (Return sends,
/// ⌥Return adds a line), a status caption and Send, a spinner while sending, or Retry after a failure.
public struct ReplyBox: View {
    let prompt: String
    let text: Binding<String>
    let state: ReplyBoxState
    let showHeading: Bool
    let isFocused: FocusState<Bool>.Binding
    let onSend: () -> Void
    let onRetry: () -> Void

    public init(prompt: String, text: Binding<String>, state: ReplyBoxState, showHeading: Bool = true,
                isFocused: FocusState<Bool>.Binding, onSend: @escaping () -> Void, onRetry: @escaping () -> Void) {
        self.prompt = prompt
        self.text = text
        self.state = state
        self.showHeading = showHeading
        self.isFocused = isFocused
        self.onSend = onSend
        self.onRetry = onRetry
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.inline) {
            if showHeading {
                Text("Reply")
                    .font(DS.Font.heading)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityHeading(.h2)
                    .help("Reply (⌘L)")
            }
            Text(prose(prompt))
                .font(DS.Font.body)
                .foregroundStyle(DS.Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
            // The owner's draft text is not sanitized.
            TextField("Reply", text: text, prompt: Text("Type a reply"), axis: .vertical)
                .lineLimit(1...8)
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
                .focused(isFocused)
                .onSubmit { if Self.canSend(text: text.wrappedValue, state: state) { onSend() } }
                .accessibilityLabel(line(prompt))
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.inline) {
                statusLine
                Spacer(minLength: DS.Space.inline)
                trailingButton
            }
        }
        .onChange(of: state) { _, new in
            if case .sent = new { AccessibilityNotification.Announcement("Sent").post() }
        }
    }

    @ViewBuilder private var statusLine: some View {
        switch state {
        case .sent:
            Label(Self.caption(state), systemImage: DS.Symbol.sent)
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.secondary)
        case .failed:
            Text(Self.caption(state))
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.error)
                .fixedSize(horizontal: false, vertical: true)
        case .idle, .sending:
            Text(Self.caption(state))
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.secondary)
        }
    }

    @ViewBuilder private var trailingButton: some View {
        switch state {
        case .failed:
            Button("Retry", action: onRetry)
        case .sending:
            Button {} label: {
                ProgressView().controlSize(DS.Control.inline).accessibilityLabel("Sending")
            }
            .disabled(true)
        case .idle, .sent:
            Button("Send", action: onSend)
                .disabled(!Self.canSend(text: text.wrappedValue, state: state))
                .help("Send (Return)")
        }
    }

    /// The caption under the field. A failure's reason goes through `line()`.
    public static func caption(_ state: ReplyBoxState) -> String {
        switch state {
        case .idle, .sending: return "Return to send · ⌥Return for a new line"
        case .sent(let at): return "Sent \(at)"
        case .failed(let reason): return "Couldn't send your reply. \(line(reason))"
        }
    }

    /// Non-blank text, and no send already in flight.
    public static func canSend(text: String, state: ReplyBoxState) -> Bool {
        state != .sending && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
