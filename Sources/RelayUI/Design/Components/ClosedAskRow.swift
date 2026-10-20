import RelayCore
import SwiftUI

/// Design/ClosedAskRow: a recently closed ask's card content, quieter than an open one
/// (CardBackground draws it with `quiet`): a faded monogram, the project and how it closed,
/// then the title in `secondary` beside Reopen.
/// Equatable on what it draws (not the actions), so the List skips cards that didn't change.
public struct ClosedAskRow: View, Equatable {
    let row: AskRowModel
    let closedLine: String
    let onReopen: () -> Void
    let onShowOnlyProject: () -> Void

    public init(row: AskRowModel, closedLine: String, onReopen: @escaping () -> Void,
                onShowOnlyProject: @escaping () -> Void) {
        self.row = row
        self.closedLine = closedLine
        self.onReopen = onReopen
        self.onShowOnlyProject = onShowOnlyProject
    }

    nonisolated public static func == (a: ClosedAskRow, b: ClosedAskRow) -> Bool {
        a.row == b.row && a.closedLine == b.closedLine
    }

    public var body: some View {
        showOnlyAction(
            VStack(alignment: .leading, spacing: DS.Space.rowLine) {
                HStack(alignment: .center, spacing: DS.Space.cardMeta) {
                    MonogramBadge(project: row.project, quiet: true)
                        .alignmentProbe(.cardText, measure: .frame)
                    Text(SectionHeader.displayName(row.project))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: DS.Space.inline)
                    Text(closedLine)
                        .lineLimit(1)
                        .monospacedDigit()
                        .layoutPriority(1)
                        .alignmentProbe(.cardTrailing, measure: .frame)
                }
                .font(DS.Font.meta)
                HStack(alignment: .center, spacing: DS.Space.inline) {
                    Text(line(row.title))
                        .font(DS.Font.body)
                        .lineLimit(2, reservesSpace: true)
                        .fixedSize(horizontal: false, vertical: true)
                        .alignmentProbe(.cardText)
                    Spacer(minLength: DS.Space.inline)
                    Button("Reopen", action: onReopen)
                        .controlSize(DS.Control.inline)
                        .help("Put it back in the queue")
                        .alignmentProbe(.cardTrailing, measure: .frame)
                }
            }
            .foregroundStyle(DS.Color.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Self.accessibilityText(row: row, closedLine: closedLine))
            .accessibilityAction(named: "Reopen", onReopen)
        )
    }

    @ViewBuilder private func showOnlyAction(_ content: some View) -> some View {
        if let title = AskRow.showOnlyTitle(project: row.project) {
            content.accessibilityAction(named: title, onShowOnlyProject)
        } else {
            content
        }
    }

    public static func accessibilityText(row: AskRowModel, closedLine: String) -> String {
        line(row.title) + ". " + closedLine
    }
}
