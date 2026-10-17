import RelayCore
import SwiftUI

/// Design/ChoiceGroup (design §3.2, §4.5): the ask's choices as a radio group, numbered for the
/// 1–9 keys, with "Sent" after each choice already sent and Send (a spinner while sending).
public struct ChoiceGroup: View {
    let prompt: String
    let choices: [String]
    let picked: Binding<Int?>
    let sent: Set<Int>
    let latestSent: Int?
    let sending: Bool
    let showHeading: Bool
    let onSend: () -> Void

    public init(prompt: String, choices: [String], picked: Binding<Int?>, sent: Set<Int>, latestSent: Int?,
                sending: Bool, showHeading: Bool = true, onSend: @escaping () -> Void) {
        self.prompt = prompt
        self.choices = choices
        self.picked = picked
        self.sent = sent
        self.latestSent = latestSent
        self.sending = sending
        self.showHeading = showHeading
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
            Picker(selection: picked) {
                ForEach(choices.indices, id: \.self) { i in
                    choiceLabel(i).tag(Optional(i))
                }
            } label: {
                Text(line(prompt))
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            .accessibilityHint(Self.hint(count: choices.count))
            HStack {
                Spacer()
                if sending {
                    ProgressView().controlSize(DS.Control.inline).accessibilityLabel("Sending")
                } else {
                    Button("Send", action: onSend)
                        .disabled(!Self.canSend(picked: picked.wrappedValue, latestSent: latestSent, sending: sending))
                }
            }
        }
    }

    private func choiceLabel(_ i: Int) -> Text {
        // Same text as Self.label(index:choice:), with the number in secondary.
        var label = Text("\(i + 1)").foregroundStyle(DS.Color.secondary) + Text("  " + line(choices[i]))
        if sent.contains(i) { label = label + Text("   Sent").foregroundStyle(DS.Color.secondary) }
        return label
    }

    /// A pick, no send in flight, and not the choice sent last.
    public static func canSend(picked: Int?, latestSent: Int?, sending: Bool) -> Bool {
        guard let picked, !sending else { return false }
        return picked != latestSent
    }

    public static func label(index: Int, choice: String) -> String { "\(index + 1)  " + line(choice) }
    public static func hint(count: Int) -> String { "Press 1 to \(count) to pick" }
}
