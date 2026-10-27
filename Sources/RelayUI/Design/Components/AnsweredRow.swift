import RelayCore
import SwiftUI

/// Design/AnsweredRow: a sent answer, "You replied: Staging · 10:42", with a green tick and
/// Change on the trailing edge (none when read-only). `prominent` sets the answer in the
/// heading font (the ask's reply); a step question's row stays in the body font.
public struct AnsweredRow: View {
    let text: String
    let time: String
    let prominent: Bool
    let changeHelp: String
    let onChange: (() -> Void)?

    /// `text` is raw ("You chose: X"); the row runs prose() on it.
    public init(text: String, time: String, prominent: Bool, changeHelp: String = "Change your answer",
                onChange: (() -> Void)?) {
        self.text = text
        self.time = time
        self.prominent = prominent
        self.changeHelp = changeHelp
        self.onChange = onChange
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.inline) {
            Image(systemName: DS.Symbol.answered)
                .foregroundStyle(DS.Color.done)
                .accessibilityHidden(true)
            label
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Self.accessibilityText(text: text, time: time))
            Spacer(minLength: DS.Space.inline)
            if let onChange {
                Button("Change", action: onChange)
                    .controlSize(DS.Control.form)
                    .help(changeHelp)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var label: Text {
        let answer = Text(verbatim: prose(text)).font(prominent ? DS.Font.heading : DS.Font.body)
        guard !time.isEmpty else { return answer }
        return answer + Text(verbatim: " · " + time).font(DS.Font.caption).foregroundStyle(DS.Color.secondary)
    }

    /// "You replied: Staging, 10:42": the time read as a clause, not after a middle dot.
    static func accessibilityText(text: String, time: String) -> String {
        time.isEmpty ? line(text) : line(text) + ", " + time
    }
}
