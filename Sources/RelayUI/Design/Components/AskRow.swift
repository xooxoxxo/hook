import RelayCore
import SwiftUI

/// Design/AskRow: an open ask's card content in the queue (CardBackground draws the card).
/// Top row: the project's monogram and name, then the urgency (as `CardUrgency` says) and the
/// compact age; then the title over up to two lines; then the subline (what the ask wants, or
/// its progress) and the draft mark. VoiceOver reads the urgency and the full age.
public struct AskRow: View {
    let row: AskRowModel
    let age: String
    let compactAge: String
    let urgencyInHeader: Bool
    let onShowOnlyProject: () -> Void

    /// `age` is the full wording VoiceOver reads ("3 h ago"), `compactAge` what the top row shows
    /// ("3h"). `urgencyInHeader`: the card sits under an Urgency section header.
    public init(row: AskRowModel, age: String, compactAge: String, urgencyInHeader: Bool = false,
                onShowOnlyProject: @escaping () -> Void) {
        self.row = row
        self.age = age
        self.compactAge = compactAge
        self.urgencyInHeader = urgencyInHeader
        self.onShowOnlyProject = onShowOnlyProject
    }

    public var body: some View {
        showOnlyAction(
            VStack(alignment: .leading, spacing: DS.Space.rowLine) {
                topRow
                titleText
                if !row.subline.isEmpty || row.hasDraft { subRow }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Self.accessibilityText(row: row, age: age))
        )
    }

    private var topRow: some View {
        HStack(alignment: .center, spacing: DS.Space.cardMeta) {
            MonogramBadge(project: row.project)
                .alignmentProbe(.cardText, measure: .frame)
            Text(SectionHeader.displayName(row.project))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: DS.Space.inline)
            meta
                .lineLimit(1)
                .monospacedDigit()
                .layoutPriority(1)
                .alignmentProbe(.cardTrailing, measure: .frame)
        }
        .font(DS.Font.meta)
        .foregroundStyle(DS.Color.secondary)
    }

    /// The urgency's symbol and word then the age ("Now · 3h"), only the symbol and the age
    /// under an Urgency header, or the age alone ("3h").
    private var meta: Text {
        let mark = CardUrgency.mark(row.urgency, headerNamesIt: urgencyInHeader)
        let urgency: Text
        switch mark {
        case .hidden: return Text(compactAge)
        case .symbol: urgency = urgencyText(row.urgency, word: false)
        case .symbolAndWord, .raw: urgency = urgencyText(row.urgency)
        }
        if compactAge.isEmpty { return urgency }
        return urgency + Text(mark == .symbol ? " " : " · ") + Text(compactAge)
    }

    @ViewBuilder private var titleText: some View {
        let title = Text(line(row.title))
            .font(DS.Font.cardTitle)
            .foregroundStyle(DS.Color.primary)
            .lineLimit(2)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .alignmentProbe(.cardText)
        if let help = Self.titleHelp(row.title) {
            title.help(help)
        } else {
            title
        }
    }

    private var subRow: some View {
        HStack(alignment: .center, spacing: DS.Space.inline) {
            if !row.subline.isEmpty {
                Text(row.subline).monospacedDigit().lineLimit(1)
            }
            if row.hasDraft {
                Image(systemName: DS.Symbol.draft).help("Unsent reply")
            }
            Spacer(minLength: DS.Space.inline)
            if case let .steps(done, total) = row.summary, row.summary.showsProgress {
                ProgressView(value: Double(done), total: Double(total))
                    .controlSize(DS.Control.inline)
                    .frame(width: DS.Metric.rowProgress)
                    .alignmentProbe(.cardTrailing, measure: .frame)
            }
        }
        .font(DS.Font.meta)
        .foregroundStyle(DS.Color.secondary)
    }

    @ViewBuilder private func showOnlyAction(_ content: some View) -> some View {
        if let title = Self.showOnlyTitle(project: row.project) {
            content.accessibilityAction(named: title, onShowOnlyProject)
        } else {
            content
        }
    }

    public static func accessibilityText(row: AskRowModel, age: String) -> String {
        var parts = [urgencyWord(row.urgency), line(row.title), SectionHeader.displayName(row.project) + ", " + age]
        if case let .steps(done, total) = row.summary, row.summary.showsProgress {
            parts.append("\(done) of \(total) steps done")
        } else if !row.subline.isEmpty {
            parts.append(row.subline)
        }
        if row.hasDraft { parts.append("Unsent reply") }
        return parts.joined(separator: ". ")
    }

    public static func titleHelp(_ title: String) -> String? { title.count > 70 ? line(title) : nil }

    /// The "Show only <project>" custom action; nil for an ask without a project.
    public static func showOnlyTitle(project: String) -> String? { project.isEmpty ? nil : "Show only " + line(project) }
}
