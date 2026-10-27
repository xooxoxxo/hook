import RelayCore
import SwiftUI

/// Design/ChoiceGroup: the ask's choices as option rows (OptionRows, single pick),
/// numbered for the 1–6 keys, with "Sent" on each choice already sent, and the reply's own
/// Send (a spinner while sending).
public struct ChoiceGroup: View {
    let prompt: String
    let choices: [String]
    let picked: Binding<Int?>
    let sent: Set<Int>
    let latestSent: Int?
    let sending: Bool
    let showHeading: Bool
    /// While changing a sent reply: Cancel, left of Send.
    let onCancel: (() -> Void)?
    let onSend: () -> Void

    public init(prompt: String, choices: [String], picked: Binding<Int?>, sent: Set<Int>, latestSent: Int?,
                sending: Bool, showHeading: Bool = true, onCancel: (() -> Void)? = nil, onSend: @escaping () -> Void) {
        self.prompt = prompt
        self.choices = choices
        self.picked = picked
        self.sent = sent
        self.latestSent = latestSent
        self.sending = sending
        self.showHeading = showHeading
        self.onCancel = onCancel
        self.onSend = onSend
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
            OptionRows(prompt: prompt, options: choices, selected: picked.wrappedValue.map { [$0] } ?? [],
                       sent: sent, disabled: sending, filled: true, numbered: true, onPick: { picked.wrappedValue = $0 })
                .accessibilityHint(Self.hint(count: choices.count))
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.inline) {
                Text(Self.hint(count: choices.count))
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.secondary)
                Spacer(minLength: DS.Space.inline)
                if sending {
                    ProgressView().controlSize(DS.Control.inline).accessibilityLabel("Sending")
                } else {
                    if let onCancel { Button("Cancel", action: onCancel).help("Keep the reply you sent") }
                    Button("Send", action: onSend)
                        .disabled(!Self.canSend(picked: picked.wrappedValue, latestSent: latestSent, sending: sending))
                }
            }
        }
    }

    /// A pick, no send in flight, and not the choice sent last.
    public static func canSend(picked: Int?, latestSent: Int?, sending: Bool) -> Bool {
        guard let picked, !sending else { return false }
        return picked != latestSent
    }

    public static func label(index: Int, choice: String) -> String { "\(index + 1)  " + line(choice) }
    public static func hint(count: Int) -> String { "Press 1 to \(count) to pick" }
}
