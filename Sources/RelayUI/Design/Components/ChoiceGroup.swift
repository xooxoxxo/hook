import RelayCore
import SwiftUI

/// Design/ChoiceGroup: the ask's choices as option rows (OptionRows, single pick),
/// numbered for the 1–6 keys, with "Sent" on each choice already sent, and the reply's own
/// Send (a spinner while sending). A choice that takes words opens its own field under it
/// when picked; its words go with the choice ("choice: Mix · words").
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
    /// Each choice's words placeholder; nil for a plain choice.
    let placeholders: [String?]
    let words: Binding<String>?
    /// The words under the sent choice differ from those sent with it.
    let newWords: Bool
    let onWordsFocus: (Bool) -> Void
    let onSend: () -> Void

    public init(prompt: String, choices: [String], picked: Binding<Int?>, sent: Set<Int>, latestSent: Int?,
                sending: Bool, showHeading: Bool = true, onCancel: (() -> Void)? = nil,
                placeholders: [String?] = [], words: Binding<String>? = nil, newWords: Bool = false,
                onWordsFocus: @escaping (Bool) -> Void = { _ in }, onSend: @escaping () -> Void) {
        self.prompt = prompt
        self.choices = choices
        self.picked = picked
        self.sent = sent
        self.latestSent = latestSent
        self.sending = sending
        self.showHeading = showHeading
        self.onCancel = onCancel
        self.placeholders = placeholders
        self.words = words
        self.newWords = newWords
        self.onWordsFocus = onWordsFocus
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
            // With only new words typed, the sent choice stays the one shown picked.
            OptionRows(prompt: prompt, options: choices,
                       selected: (picked.wrappedValue ?? (words != nil ? latestSent : nil)).map { [$0] } ?? [],
                       sent: sent, disabled: sending, filled: true, numbered: true,
                       placeholders: placeholders, words: words, onWordsFocus: onWordsFocus,
                       onPick: { picked.wrappedValue = $0 })
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
                        .disabled(!Self.canSend(picked: picked.wrappedValue, latestSent: latestSent, sending: sending,
                                                newWords: newWords) || wordsOver)
                }
            }
        }
    }

    /// The words under the picked word choice run past the cap: Send stays off.
    private var wordsOver: Bool {
        guard let words, let index = picked.wrappedValue ?? latestSent, placeholders.indices.contains(index),
              placeholders[index] != nil else { return false }
        return AnswerDrafts.wordsOver(words.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)) != nil
    }

    /// No send in flight, and a pick other than the choice sent last, or new words on it.
    public static func canSend(picked: Int?, latestSent: Int?, sending: Bool, newWords: Bool = false) -> Bool {
        guard !sending, let choice = picked ?? (newWords ? latestSent : nil) else { return false }
        return choice != latestSent || newWords
    }

    public static func label(index: Int, choice: String) -> String { "\(index + 1)  " + line(choice) }
    public static func hint(count: Int) -> String { "Press 1 to \(count) to pick" }
}
