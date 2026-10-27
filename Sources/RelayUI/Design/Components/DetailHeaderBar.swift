import RelayCore
import SwiftUI

/// Design/DetailHeaderBar: Back, the ask's project · urgency · age on one
/// baseline, then the ask's menu (when it has entries), Previous, Next and Hide. Previous
/// and Next are disabled unless the neighbour is an ask in the (filtered) queue.
public struct DetailHeaderBar: View {
    let project: String
    let urgency: Urgency
    let age: String
    let previous: Neighbour
    let next: Neighbour
    let onBack: () -> Void
    let onPrevious: () -> Void
    let onNext: () -> Void
    let onHide: () -> Void
    let onDock: (SidebarEdge) -> Void
    let menu: [ContextMenuEntry]
    let onMenu: (ContextCommand) -> Void

    public init(project: String, urgency: Urgency, age: String, previous: Neighbour, next: Neighbour,
                onBack: @escaping () -> Void, onPrevious: @escaping () -> Void, onNext: @escaping () -> Void,
                onHide: @escaping () -> Void, onDock: @escaping (SidebarEdge) -> Void,
                menu: [ContextMenuEntry] = [], onMenu: @escaping (ContextCommand) -> Void = { _ in }) {
        self.project = project
        self.urgency = urgency
        self.age = age
        self.previous = previous
        self.next = next
        self.onBack = onBack
        self.onPrevious = onPrevious
        self.onNext = onNext
        self.onHide = onHide
        self.onDock = onDock
        self.menu = menu
        self.onMenu = onMenu
    }

    public var body: some View {
        PanelHeader(onDock: onDock) {
            IconButton(DS.Symbol.back, label: "Back to the queue", help: "Back to the queue (Esc)", action: onBack)
            Self.meta(project: project, urgency: urgency, age: age)
                .font(DS.Font.meta)
                .foregroundStyle(DS.Color.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .accessibilityLabel(Self.metaText(project: project, urgency: urgency, age: age))
            Spacer()
            HStack(spacing: DS.Space.inline) {
                if !menu.isEmpty { askMenu }
                IconButton(DS.Symbol.prev, label: "Previous ask", help: Self.neighbourHelp(previous, previous: true), action: onPrevious)
                    .disabled(!isAsk(previous))
                IconButton(DS.Symbol.next, label: "Next ask", help: Self.neighbourHelp(next, previous: false), action: onNext)
                    .disabled(!isAsk(next))
                IconButton(DS.Symbol.hide, label: "Hide Hook", help: Self.hideHelp, action: onHide)
            }
        }
    }

    /// A stock pull-down with the same entries as the queue's context menu, drawn and
    /// hit-tested like QueueMenu's.
    private var askMenu: some View {
        Menu {
            RowContextMenu(entries: menu, perform: onMenu)
        } label: {
            Image(systemName: DS.Symbol.more)
                .foregroundStyle(DS.Color.secondary)
                .frame(minWidth: DS.Metric.hit, minHeight: DS.Metric.hit)
                .contentShape(.rect)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(Self.menuLabel)
        .help(Self.menuLabel)
    }

    public static let menuLabel = "Session"

    private func isAsk(_ n: Neighbour) -> Bool {
        if case .ask = n { return true }
        return false
    }

    /// One `Text`, so the urgency symbol shares the line's baseline.
    public static func meta(project: String, urgency: Urgency, age: String) -> Text {
        Text(project.isEmpty ? "—" : line(project)) + Text(" · ") + urgencyText(urgency) + Text(" · ") + Text(age).monospacedDigit()
    }

    /// The same line as plain text, for VoiceOver.
    public static func metaText(project: String, urgency: Urgency, age: String) -> String {
        (project.isEmpty ? "—" : line(project)) + " · " + urgencyWord(urgency) + " · " + age
    }

    /// Esc goes back to the list in detail, so Hide names ⌘W here.
    public static let hideHelp = "Hide (⌘W)"

    public static func neighbourHelp(_ n: Neighbour, previous: Bool) -> String {
        if n == .outsideFilter { return "Not in the filtered queue" }
        return previous ? "Previous ask (⌘↑)" : "Next ask (⌘↓)"
    }
}
