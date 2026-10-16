import RelayCore
import SwiftUI

/// Design/AskRow (design §4.2): an open ask in the queue. Line 1 is the title alone in both
/// groupings; line 2 shows what the grouping doesn't (urgency in Project grouping, project
/// in Urgency grouping), then the age, the draft mark and the summary.
public struct AskRow: View {
    let row: AskRowModel
    let age: String
    let grouping: QueueGrouping
    /// True when this row is the list selection. Offscreen (and in the macOS 15 sidebar List)
    /// `backgroundProminence` stays `.standard` on the selected row, so the caller passes it too.
    let selected: Bool
    let onShowOnlyProject: () -> Void
    @Environment(\.backgroundProminence) private var prominence

    public init(row: AskRowModel, age: String, grouping: QueueGrouping, selected: Bool,
                onShowOnlyProject: @escaping () -> Void) {
        self.row = row
        self.age = age
        self.grouping = grouping
        self.selected = selected
        self.onShowOnlyProject = onShowOnlyProject
    }

    private var onAccent: Bool { selected || prominence == .increased }

    public var body: some View {
        showOnlyAction(
            VStack(alignment: .leading, spacing: DS.Space.rowLine) {
                titleText
                HStack(alignment: .firstTextBaseline, spacing: DS.Space.rowLine) {
                    lineTwo.monospacedDigit()
                    if row.hasDraft {
                        Image(systemName: DS.Symbol.draft).help("Unsent reply")
                    }
                    Spacer(minLength: DS.Space.inline)
                    summaryView.alignmentProbe(.trailingEdge)
                }
                .font(DS.Font.meta)
                .foregroundStyle(DS.Color.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Self.accessibilityText(row: row, age: age))
        )
    }

    @ViewBuilder private var titleText: some View {
        let title = Text(line(row.title))
            .font(DS.Font.body)
            .lineLimit(2)
            .alignmentProbe(.gutterText)
        if let help = Self.titleHelp(row.title) {
            title.help(help)
        } else {
            title
        }
    }

    private var lineTwo: Text {
        switch grouping {
        case .project:
            urgencyText(row.urgency, prominent: onAccent) + Text(" · " + age)
        case .urgency:
            Text((row.project.isEmpty ? "—" : line(row.project)) + " · " + age)
        }
    }

    @ViewBuilder private var summaryView: some View {
        switch row.summary {
        case let .steps(done, total):
            HStack(alignment: .center, spacing: DS.Space.inline) {
                if row.summary.showsProgress {
                    ProgressView(value: Double(done), total: Double(total))
                        .controlSize(DS.Control.inline)
                        .frame(width: DS.Metric.rowProgress)
                }
                Text(row.summary.text).monospacedDigit()
            }
        case .none:
            EmptyView()
        default:
            Text(row.summary.text)
        }
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
        switch row.summary {
        case let .steps(done, total): parts.append("\(done) of \(total) steps done")
        case .none: break
        default: parts.append(row.summary.text)
        }
        if row.hasDraft { parts.append("Unsent reply") }
        return parts.joined(separator: ". ")
    }

    public static func titleHelp(_ title: String) -> String? { title.count > 70 ? line(title) : nil }

    /// The "Show only <project>" custom action; nil for an ask without a project.
    public static func showOnlyTitle(project: String) -> String? { project.isEmpty ? nil : "Show only " + line(project) }
}
