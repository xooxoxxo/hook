import RelayCore
import SwiftUI

/// Design/QueueMenu (design §4.1): the header's one icon-only pull-down (rule A3), a stock
/// `Menu` with Group by and Project sections. The symbol fills in the accent while a filter is on.
public struct QueueMenu: View {
    let grouping: Binding<QueueGrouping>
    let filter: Binding<String?>
    let projects: [MenuProject]

    public init(grouping: Binding<QueueGrouping>, filter: Binding<String?>, projects: [MenuProject]) {
        self.grouping = grouping
        self.filter = filter
        self.projects = projects
    }

    public var body: some View {
        let filtered = filter.wrappedValue != nil
        Menu {
            Section("Group by") {
                Picker("Group by", selection: grouping) {
                    Text("Project").tag(QueueGrouping.project)
                    Text("Urgency").tag(QueueGrouping.urgency)
                }
                .pickerStyle(.inline).labelsHidden()
            }
            Section("Project") {
                Picker("Project", selection: filter) {
                    Text("All Projects").tag(String?.none)
                    ForEach(projects) { Text(Self.itemTitle($0)).tag(Optional($0.name)) }
                }
                .pickerStyle(.inline).labelsHidden()
            }
        } label: {
            Image(systemName: filtered ? DS.Symbol.filterOn : DS.Symbol.filter)
                .foregroundStyle(filtered ? DS.Color.accent : DS.Color.secondary)
                // Rule A3: the frame and shape sit inside the label, so the click region is
                // the 28 pt square. `.borderlessButton` would draw the label as a glyph-sized
                // NSPopUpButton that ignores this frame, and clicks on the padding around it
                // would reach the header's drag handle. A plain-styled button menu lets
                // SwiftUI draw and hit-test the label itself.
                .frame(minWidth: DS.Metric.hit, minHeight: DS.Metric.hit)
                .contentShape(.rect)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .tint(filtered ? DS.Color.accent : DS.Color.secondary)
        .accessibilityLabel("Group and filter")
        .accessibilityValue(Self.accessibilityValue(grouping: grouping.wrappedValue, filter: filter.wrappedValue))
        .help(Self.help)
    }

    public static let help = "Group and filter · ⌃⌘G switches grouping"

    public static func accessibilityValue(grouping: QueueGrouping, filter: String?) -> String {
        "Grouped by \(grouping.rawValue), " + (filter.map { "showing " + SectionHeader.displayName($0) } ?? "all projects")
    }

    public static func itemTitle(_ project: MenuProject) -> String {
        SectionHeader.displayName(project.name) + " (\(project.open))"
    }
}
