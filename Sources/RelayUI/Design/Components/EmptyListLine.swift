import RelayCore
import SwiftUI

/// Design/EmptyListLine: the in-list line when no open ask is shown but some
/// recently closed are. With a filter on it names the project and offers Show All Projects.
public struct EmptyListLine: View {
    let project: String?
    let onShowAll: () -> Void

    public init(project: String?, onShowAll: @escaping () -> Void) {
        self.project = project
        self.onShowAll = onShowAll
    }

    public var body: some View {
        VStack(spacing: DS.Space.inline) {
            Text(Self.text(project: project))
                .foregroundStyle(DS.Color.tertiary)
            if project != nil {
                Button("Show All Projects", action: onShowAll)
                    .controlSize(DS.Control.inline)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, DS.Space.emptyLine)
    }

    public static func text(project: String?) -> String {
        project.map { "Nothing waiting in " + SectionHeader.displayName($0) } ?? "Nothing waiting"
    }
}
