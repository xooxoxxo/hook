import RelayCore
import SwiftUI

/// Design/OptionRows: the one option list for reply choices and step questions, single or
/// multi pick. Grouped rows on a hairline outline: the reply's choices lead with their number
/// (the 1–6 keys pick them; `numbered`), step questions don't, since no key picks those. Then the
/// choice in body text and a trailing mark: a checkmark on the picked single option, a
/// checkbox on each multi option. VoiceOver reads a radio group or checkboxes
/// (`accessibilityRepresentation`), never plain buttons.
public struct OptionRows: View {
    /// The question, as VoiceOver names the group. Raw; sanitized here.
    let prompt: String
    let options: [String]
    let multi: Bool
    let selected: Set<Int>
    /// Options already sent: they carry "Sent" before the mark.
    let sent: Set<Int>
    let disabled: Bool
    /// Draw the group fill under the rows: for a list that sits on the panel, not inside a StepGroup.
    let filled: Bool
    /// Lead each row with its number: only for the reply's choices, which the digit keys pick.
    let numbered: Bool
    /// Single: pick `index`. Multi: flip it.
    let onPick: (Int) -> Void

    public init(prompt: String, options: [String], multi: Bool = false, selected: Set<Int>, sent: Set<Int> = [],
                disabled: Bool = false, filled: Bool = false, numbered: Bool = false, onPick: @escaping (Int) -> Void) {
        self.prompt = prompt
        self.options = options
        self.multi = multi
        self.selected = selected
        self.sent = sent
        self.disabled = disabled
        self.filled = filled
        self.numbered = numbered
        self.onPick = onPick
    }

    /// The trailing mark's symbol, or nil when nothing shows (an unpicked single option).
    public static func mark(multi: Bool, selected: Bool) -> String? {
        if multi { return selected ? DS.Symbol.checkboxOn : DS.Symbol.checkboxOff }
        return selected ? DS.Symbol.optionPicked : nil
    }

    /// What VoiceOver reads for one option: "1, Staging" (numbered) or "Staging", plus ", sent".
    public static func accessibilityText(index: Int, option: String, sent: Bool, numbered: Bool = true) -> String {
        (numbered ? "\(index + 1), " : "") + line(option) + (sent ? ", sent" : "")
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: DS.Metric.optionRadius, style: .continuous)
        let rows = VStack(alignment: .leading, spacing: 0) {
            ForEach(options.indices, id: \.self) { i in
                if i > 0 { Divider().padding(.leading, numbered ? DS.Space.optionText : DS.Space.optionH) }
                row(i)
            }
        }
        .background(filled ? DS.Color.groupFill : Color.clear)
        .clipShape(shape)
        .overlay(shape.strokeBorder(DS.Color.optionStroke, lineWidth: DS.Metric.cardBorder))
        .disabled(disabled)
        if multi {
            rows
                .accessibilityElement(children: .contain)
                .accessibilityLabel(line(prompt))
        } else {
            rows.accessibilityRepresentation {
                Picker(selection: Binding<Int?>(get: { selected.first }, set: { if let i = $0 { onPick(i) } })) {
                    ForEach(options.indices, id: \.self) { i in
                        Text(verbatim: Self.accessibilityText(index: i, option: options[i], sent: sent.contains(i), numbered: numbered))
                            .tag(Optional(i))
                    }
                } label: {
                    Text(verbatim: line(prompt))
                }
                .pickerStyle(.radioGroup)
                .disabled(disabled)
            }
        }
    }

    @ViewBuilder private func row(_ i: Int) -> some View {
        let isOn = selected.contains(i)
        let button = Button { onPick(i) } label: {
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.inline) {
                if numbered {
                    Text(verbatim: "\(i + 1)")
                        .font(DS.Font.meta)
                        .monospacedDigit()
                        .foregroundStyle(DS.Color.secondary)
                        .frame(width: DS.Metric.optionNumber, alignment: .leading)
                }
                Text(verbatim: line(options[i]))
                    .font(DS.Font.body)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: DS.Space.inline)
                if sent.contains(i) {
                    Text("Sent").font(DS.Font.caption).foregroundStyle(DS.Color.secondary)
                }
                Image(systemName: Self.mark(multi: multi, selected: isOn) ?? DS.Symbol.optionPicked)
                    .font(DS.Font.body.weight(.semibold))
                    .foregroundStyle(isOn ? AnyShapeStyle(DS.Color.accent) : AnyShapeStyle(DS.Color.tertiary))
                    .opacity(Self.mark(multi: multi, selected: isOn) == nil ? 0 : 1)
            }
            .padding(.horizontal, DS.Space.optionH)
            .padding(.vertical, DS.Space.optionV)
            .frame(maxWidth: .infinity, minHeight: DS.Metric.optionRow, alignment: .leading)
            .background(isOn ? DS.Color.optionSelected : Color.clear)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        if multi {
            button.accessibilityRepresentation {
                Toggle(isOn: Binding(get: { isOn }, set: { _ in onPick(i) })) {
                    Text(verbatim: Self.accessibilityText(index: i, option: options[i], sent: sent.contains(i), numbered: numbered))
                }
                .toggleStyle(.checkbox)
                .disabled(disabled)
            }
        } else {
            button
        }
    }
}
