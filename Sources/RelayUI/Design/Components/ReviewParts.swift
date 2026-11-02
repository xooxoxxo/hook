import RelayCore
import SwiftUI

/// Design/StepTag: a step's small capsule tag in a corrected ask ("Changed", "New", "Removed").
public struct StepTag: View {
    let title: String
    let color: Color

    public init(_ title: String, color: Color) {
        self.title = title
        self.color = color
    }

    public init(_ chip: StepChip) {
        self.init(chip.title, color: StepTag.color(chip))
    }

    public var body: some View {
        Text(verbatim: title)
            .font(DS.Font.caption.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(color.opacity(DS.Color.tagFillOpacity), in: .capsule)
            .fixedSize()
    }

    /// The text tints (`DS.Color.warnText`…), which reach 4.5:1 at 11 pt in both themes.
    public static func color(_ chip: StepChip) -> Color {
        switch chip {
        case .changed: return DS.Color.warnText
        case .new: return DS.Color.doneText
        case .removed: return DS.Color.errorText
        }
    }

    /// A review row's tag colour, by its change.
    public static func color(_ change: ReviewPage.Change) -> Color {
        switch change {
        case .changed: return DS.Color.warnText
        case .added: return DS.Color.doneText
        case .removed: return DS.Color.errorText
        case .moved, .same: return DS.Color.secondary
        }
    }
}

/// Design/UnifiedDiff: one field of a review, a "−" line over a "+" line, the changed words
/// filled (and struck through on the old line, bold on the new). Never selectable: the review
/// shows what changed, it is not a place to copy from.
public struct UnifiedDiff: View {
    let field: ReviewPage.Field

    public init(_ field: ReviewPage.Field) {
        self.field = field
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let label = field.label {
                Text(verbatim: label).font(DS.Font.caption).foregroundStyle(DS.Color.secondary)
            }
            VStack(alignment: .leading, spacing: 0) {
                if field.hasOld {
                    line(glyph: "−", text: Self.text(field.tokens, old: true, monospaced: field.monospaced),
                         fill: DS.Color.diffRemovedLine)
                }
                if field.hasNew {
                    line(glyph: "+", text: Self.text(field.tokens, old: false, monospaced: field.monospaced),
                         fill: DS.Color.diffAddedLine)
                }
            }
            .clipShape(.rect(cornerRadius: DS.Metric.codeRadius))
        }
        .textSelection(.disabled)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.accessibilityText(field))
    }

    private func line(glyph: String, text: AttributedString, fill: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(verbatim: glyph).font(DS.Font.code.weight(.bold)).foregroundStyle(DS.Color.secondary)
            Text(text)
                .font(field.monospaced ? DS.Font.code : DS.Font.prose)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, DS.Space.codeH)
        .padding(.vertical, 6)
        .background(fill)
    }

    /// One side: `old` keeps the same and removed runs, the new side the same and added ones.
    static func text(_ tokens: [DiffToken], old: Bool, monospaced: Bool) -> AttributedString {
        var out = AttributedString()
        for token in tokens {
            switch token {
            case .same(let text):
                out += AttributedString(text)
            case .removed(let text) where old:
                var piece = AttributedString(text)
                piece.backgroundColor = DS.Color.diffRemovedWord
                piece.strikethroughStyle = .single
                out += piece
            case .added(let text) where !old:
                var piece = AttributedString(text)
                piece.backgroundColor = DS.Color.diffAddedWord
                piece.font = (monospaced ? DS.Font.code : DS.Font.prose).weight(.semibold)
                out += piece
            default:
                break
            }
        }
        return out
    }

    /// "Command. Was: … Now: …", or "Detail. Added: …".
    public static func accessibilityText(_ field: ReviewPage.Field) -> String {
        let old = field.tokens.compactMap { token -> String? in
            if case .added = token { return nil }
            return token.text
        }.joined()
        let new = field.tokens.compactMap { token -> String? in
            if case .removed = token { return nil }
            return token.text
        }.joined()
        let name = field.label ?? "Command"
        switch (field.hasOld, field.hasNew) {
        case (true, true): return "\(name). Was: \(old). Now: \(new)"
        case (false, true): return "\(name). Added: \(new)"
        case (true, false): return "\(name). Removed: \(old)"
        case (false, false): return name
        }
    }
}

/// Design/LookCloserLine: one flag, right below the diff it was found in.
public struct LookCloserLine: View {
    let flag: ReviewPage.Flag

    public init(_ flag: ReviewPage.Flag) {
        self.flag = flag
    }

    public var body: some View {
        Label {
            Text(verbatim: flag.title)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: DS.Symbol.lookCloser).accessibilityHidden(true)
        }
        .font(DS.Font.caption.weight(.medium))
        .foregroundStyle(DS.Color.warnText)
        .accessibilityLabel("Look closer: " + flag.title)
    }
}

/// Design/ReviewBar: the sticky bar of a corrected ask, in place of the action bar. A tinted
/// strip, the title and detail with a "?" beside them, then the buttons.
public struct ReviewBar<Buttons: View>: View {
    public enum Tone { case correction, history }

    let tone: Tone
    let title: String
    let detail: String
    let help: String
    let buttons: Buttons

    public init(tone: Tone, title: String, detail: String, help: String, @ViewBuilder buttons: () -> Buttons) {
        self.tone = tone
        self.title = title
        self.detail = detail
        self.help = help
        self.buttons = buttons()
    }

    private var color: Color { tone == .history ? DS.Color.error : DS.Color.warn }

    public var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(color).frame(height: 2).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: DS.Space.inline) {
                HStack(alignment: .firstTextBaseline, spacing: DS.Space.inline) {
                    Image(systemName: tone == .history ? DS.Symbol.warning : DS.Symbol.corrected)
                        .foregroundStyle(color)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(verbatim: title).font(DS.Font.prose.weight(.semibold))
                        Text(verbatim: detail)
                            .font(DS.Font.caption)
                            .foregroundStyle(DS.Color.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .combine)
                    Spacer(minLength: 0)
                    HelpButton(rowLabel: title, text: help)
                }
                HStack(spacing: DS.Space.inline) { buttons }
                    .controlSize(DS.Control.action)
            }
            .padding(.horizontal, DS.Space.gutter)
            .padding(.vertical, DS.Space.barStackV + 2)
            .background(tone == .history ? DS.Color.errorFill : DS.Color.warnFill)
        }
        .background(DS.Color.bar)
    }
}

/// Design/ReasonQuote: a reason the session gave, in a bordered quote under its version and time.
public struct ReasonQuote: View {
    let reason: ReviewPage.Reason

    public init(_ reason: ReviewPage.Reason) {
        self.reason = reason
    }

    public var body: some View {
        HStack(alignment: .top, spacing: DS.Space.inline) {
            RoundedRectangle(cornerRadius: 1.5).fill(.tertiary).frame(width: 3).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: reason.heading).font(DS.Font.caption).foregroundStyle(DS.Color.secondary)
                Text(verbatim: reason.text)
                    .font(DS.Font.prose)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }
}

/// Design/ReviewRow: one row of the review: its number, text and tag, then "Was:", the diffs and the flags.
/// An unchanged step is its text only, dimmed (`Row.dimmed`; never on a first view, nor with a diff or flag).
public struct ReviewRow: View {
    let row: ReviewPage.Row

    public init(row: ReviewPage.Row) {
        self.row = row
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.marker) {
            marker
            VStack(alignment: .leading, spacing: DS.Space.stepPart) {
                HStack(alignment: .firstTextBaseline, spacing: DS.Space.inline) {
                    Text(verbatim: row.action)
                        .font(DS.Font.body)
                        .strikethrough(row.change == .removed)
                        .foregroundStyle(row.dimmed ? DS.Color.secondary : DS.Color.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    if let tag = row.tag { StepTag(tag, color: StepTag.color(row.change)) }
                }
                if let was = row.was {
                    Text(verbatim: "Was: " + was).font(DS.Font.caption).foregroundStyle(DS.Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let note = row.note {
                    Text(verbatim: note).font(DS.Font.caption).foregroundStyle(DS.Color.secondary)
                }
                ForEach(Array(row.fields.enumerated()), id: \.offset) { _, field in
                    UnifiedDiff(field)
                }
                ForEach(Array(row.flags.enumerated()), id: \.offset) { _, flag in
                    LookCloserLine(flag)
                }
            }
        }
        .padding(.leading, row.isSub ? DS.Space.subIndent : 0)
        .padding(.horizontal, DS.Space.groupRowH)
        .padding(.vertical, DS.Space.groupRowV)
        .opacity(row.dimmed ? DS.Color.lockedOpacity : 1)
        .accessibilityElement(children: .contain)
    }

    /// The step's number in a circle, a sub-step's or another part's label as text.
    @ViewBuilder private var marker: some View {
        Group {
            if let n = Int(row.label), (1...50).contains(n) {
                Image(systemName: DS.Symbol.stepTodo(n))
                    .font(.title3)
                    .foregroundStyle(.tertiary)
            } else if row.label == "Verify" {
                Image(systemName: DS.Symbol.verifyTodo)
                    .font(.title3)
                    .foregroundStyle(.tertiary)
            } else {
                Text(verbatim: row.label)
                    .font(DS.Font.caption.weight(.semibold))
                    .foregroundStyle(DS.Color.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
        .frame(width: DS.Metric.hit)
        .accessibilityLabel(row.label.first?.isNumber == true ? "Step " + row.label : row.label)
    }
}

