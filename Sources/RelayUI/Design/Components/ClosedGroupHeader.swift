import SwiftUI

/// Design/ClosedGroupHeader: the Recently closed section's header is its
/// disclosure, laid out like a SectionHeader. The closed rows are the section's own rows.
public struct ClosedGroupHeader: View {
    let count: Int
    @Binding var expanded: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(count: Int, expanded: Binding<Bool>) {
        self.count = count
        _expanded = expanded
    }

    public var body: some View {
        Button {
            withAnimation(DS.motion(DS.Motion.reveal, reduce: reduceMotion)) {
                expanded.toggle()
            }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.inline) {
                Text("Recently closed")
                    .alignmentProbe(.gutterText)
                Spacer(minLength: DS.Space.inline)
                Text("\(count)").monospacedDigit()
                Image(systemName: expanded ? DS.Symbol.disclosureOpen : DS.Symbol.disclosureClosed)
                    .imageScale(.small)
                    .alignmentProbe(.trailingEdge)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(DS.Color.secondary)
        .padding(.leading, DS.Space.sectionHeaderLead)
        .padding(.trailing, DS.Space.gutter - DS.Space.sectionHeaderLead)
        .help("Asks closed in the last 24 hours")
        .accessibilityLabel(Self.accessibilityText(count: count))
        .accessibilityValue(TrailingDisclosureStyle.value(expanded: expanded))
    }

    public static func accessibilityText(count: Int) -> String {
        "Recently closed, \(count) \(count == 1 ? "ask" : "asks")"
    }
}
