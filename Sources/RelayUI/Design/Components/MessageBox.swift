import RelayCore
import SwiftUI

/// Design/MessageBox: the Messages section's multi-line field (Return adds a line; ⌘Return
/// sends, through the panel's key router, so it never triggers Done), its caption, the counter
/// past 80 % of the limit, and Send. The field grows to 8 lines, then scrolls. A paste over the
/// limit is kept: the caption says how much to trim and Send stays off. A refusal shows its
/// reason in place of the caption.
public struct MessageBox: View {
    let text: Binding<String>
    let limits: TalkLimits
    let state: MessageBoxState
    let isFocused: FocusState<Bool>.Binding
    let onSend: () -> Void

    public init(text: Binding<String>, limits: TalkLimits, state: MessageBoxState, isFocused: FocusState<Bool>.Binding,
                onSend: @escaping () -> Void) {
        self.text = text
        self.limits = limits
        self.state = state
        self.isFocused = isFocused
        self.onSend = onSend
    }

    public static func canSend(_ text: String, limits: TalkLimits, state: MessageBoxState) -> Bool {
        MessageText.canSend(text, limits: limits) && state != .sending
    }

    private var count: Int { MessageText.count(text.wrappedValue) }

    public var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.inline) {
            MultilineField(MessageText.placeholder, text: text, lines: DS.Metric.fieldLines, isFocused: isFocused)
                .disabled(state == .sending)
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.inline) {
                caption
                Spacer(minLength: DS.Space.inline)
                LimitCounter(count: count, limit: limits.message)
                sendButton
            }
            .controlSize(DS.Control.form)
        }
    }

    @ViewBuilder private var caption: some View {
        if case .failed(let reason) = state {
            Text(line(reason))
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.errorText)
                .fixedSize(horizontal: false, vertical: true)
        } else if LimitCaption.text(count: count, limit: limits.message) != nil {
            LimitCaption(count: count, limit: limits.message)
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
                .disabled(!Self.canSend(text.wrappedValue, limits: limits, state: state))
                .help("Send (⌘Return)")
        }
    }
}
