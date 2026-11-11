import RelayUI
import RelayCore
import SwiftUI

/// Design/ListHeaderBar: the queue's header. The title ("Queue") sits on the gutter, and
/// VoiceOver hears the count with it ("Queue, 5 waiting"); the refresh spinner, QueueMenu, Refresh and Hide sit on the right.
/// While a project filter is on, the FilterRow shows under the bar.
public struct ListHeaderBar: View {
    let title: String
    let waiting: Int
    let refreshing: Bool
    let updated: String
    let grouping: Binding<QueueGrouping>
    let filter: Binding<String?>
    let projects: [MenuProject]
    let hidden: HiddenCount
    let onRefresh: () -> Void
    let onHide: () -> Void
    let onDock: (SidebarEdge) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(title: String, waiting: Int = 0, refreshing: Bool, updated: String, grouping: Binding<QueueGrouping>, filter: Binding<String?>,
                projects: [MenuProject], hidden: HiddenCount,
                onRefresh: @escaping () -> Void, onHide: @escaping () -> Void, onDock: @escaping (SidebarEdge) -> Void) {
        self.title = title
        self.waiting = waiting
        self.refreshing = refreshing
        self.updated = updated
        self.grouping = grouping
        self.filter = filter
        self.projects = projects
        self.hidden = hidden
        self.onRefresh = onRefresh
        self.onHide = onHide
        self.onDock = onDock
    }

    public var body: some View {
        VStack(spacing: 0) {
            PanelHeader(onDock: onDock) {
                Text(title)
                    .font(DS.Font.listTitle)
                    .monospacedDigit()
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityLabel(Self.accessibilityTitle(waiting: waiting))
                    .alignmentProbe(.gutterText, measure: .frame)
                Spacer()
                HStack(alignment: .center, spacing: DS.Space.inline) {
                    if refreshing {
                        ProgressView().controlSize(DS.Control.inline).accessibilityLabel("Refreshing")
                    }
                    QueueMenu(grouping: grouping, filter: filter, projects: projects)
                    IconButton(DS.Symbol.refresh, label: "Refresh", help: Self.refreshHelp(updated: updated), action: onRefresh)
                        .keyboardShortcut("r")
                    IconButton(DS.Symbol.hide, label: "Hide Hook", help: "Hide (Esc)", action: onHide)
                }
            }
            if let project = filter.wrappedValue {
                FilterRow(project: project, hidden: hidden, onClear: { filter.wrappedValue = nil })
                    .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
            }
        }
        .motion(DS.Motion.reveal, value: filter.wrappedValue)
    }

    /// "Queue, 5 waiting" / "Queue, nothing waiting".
    public static func accessibilityTitle(waiting: Int) -> String {
        "Queue, " + (waiting == 0 ? "nothing waiting" : "\(waiting) waiting")
    }

    public static func refreshHelp(updated: String) -> String {
        updated.isEmpty ? "Refresh (⌘R)" : "Refresh (⌘R) · updated \(updated)"
    }
}
