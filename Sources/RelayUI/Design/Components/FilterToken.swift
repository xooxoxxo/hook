import RelayCore
import SwiftUI

/// Design/FilterToken: the filtered project's name and a clear mark, as one
/// bordered button that shows all projects again. A long name truncates inside the token.
public struct FilterToken: View {
    let project: String
    let onClear: () -> Void

    public init(project: String, onClear: @escaping () -> Void) {
        self.project = project
        self.onClear = onClear
    }

    public var body: some View {
        Button(action: onClear) {
            HStack(spacing: DS.Space.rowLine) {
                Text(SectionHeader.displayName(project)).lineLimit(1).truncationMode(.tail)
                Image(systemName: DS.Symbol.clearFilter).foregroundStyle(DS.Color.secondary)
            }
        }
        .buttonStyle(.bordered)
        .controlSize(DS.Control.inline)
        .frame(maxWidth: DS.Metric.filterTokenMax, alignment: .leading)
        .layoutPriority(0)
        .accessibilityLabel(Self.accessibilityText(project))
        .help("Show all projects (⌃⌘A)")
    }

    public static func accessibilityText(_ project: String) -> String {
        "Showing only \(SectionHeader.displayName(project)). Show all projects"
    }
}
