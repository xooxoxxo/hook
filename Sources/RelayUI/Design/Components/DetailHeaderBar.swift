import RelayCore
import SwiftUI

/// Design/DetailHeaderBar: Back, the ask's project · urgency · age on one
/// baseline, then Previous, Next and Hide. Previous and Next are disabled unless the
/// neighbour is an ask in the (filtered) queue.
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

    public init(project: String, urgency: Urgency, age: String, previous: Neighbour, next: Neighbour,
                onBack: @escaping () -> Void, onPrevious: @escaping () -> Void, onNext: @escaping () -> Void,
                onHide: @escaping () -> Void, onDock: @escaping (SidebarEdge) -> Void) {
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
                IconButton(DS.Symbol.prev, label: "Previous ask", help: Self.neighbourHelp(previous, previous: true), action: onPrevious)
                    .disabled(!isAsk(previous))
                IconButton(DS.Symbol.next, label: "Next ask", help: Self.neighbourHelp(next, previous: false), action: onNext)
                    .disabled(!isAsk(next))
                IconButton(DS.Symbol.hide, label: "Hide Hook", help: Self.hideHelp, action: onHide)
            }
        }
    }

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
