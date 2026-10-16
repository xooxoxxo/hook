import RelayCore
import SwiftUI

/// Design/SectionHeader (design §3.2): a queue section's name and count, in `secondary`.
/// The name is a project (or "No project") or an urgency word.
public struct SectionHeader: View {
    let name: String
    let count: Int

    public init(name: String, count: Int) {
        self.name = name
        self.count = count
    }

    public var body: some View {
        HStack {
            Text(Self.displayName(name))
                .lineLimit(1)
                .truncationMode(.tail)
                .alignmentProbe(.gutterText)
            Spacer()
            Text("\(count)")
                .monospacedDigit()
                .alignmentProbe(.trailingEdge)
        }
        .foregroundStyle(DS.Color.secondary)
        .padding(.leading, DS.Space.sectionHeaderLead)
        .padding(.trailing, DS.Space.gutter - DS.Space.sectionHeaderLead)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.accessibilityText(name: name, count: count))
        .accessibilityAddTraits(.isHeader)
    }

    public static func displayName(_ name: String) -> String { name.isEmpty ? "No project" : line(name) }

    public static func accessibilityText(name: String, count: Int) -> String {
        "\(displayName(name)), \(count) \(count == 1 ? "ask" : "asks")"
    }
}
