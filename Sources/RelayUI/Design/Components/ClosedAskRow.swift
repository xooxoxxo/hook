import RelayCore
import SwiftUI

/// Design/ClosedAskRow (design §4.2): a recently closed ask, in `secondary`, with Reopen.
public struct ClosedAskRow: View {
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

    public var body: some View {
        showOnlyAction(
            HStack(alignment: .center, spacing: DS.Space.inline) {
                VStack(alignment: .leading, spacing: DS.Space.rowLine) {
                    Text(line(row.title))
                        .font(DS.Font.body)
                        .foregroundStyle(DS.Color.secondary)
                        .lineLimit(1)
                        .alignmentProbe(.gutterText)
                    Text(line(row.project.isEmpty ? "—" : row.project) + " · " + closedLine)
                        .font(DS.Font.meta)
                        .foregroundStyle(DS.Color.secondary)
                        .monospacedDigit()
                }
                Spacer(minLength: DS.Space.inline)
                Button("Reopen", action: onReopen)
                    .controlSize(DS.Control.inline)
                    .help("Put it back in the queue")
                    .alignmentProbe(.trailingEdge, measure: .frame)
            }
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
