import RelayCore
import SwiftUI

/// The names of the panel header's VoiceOver actions and the drag surface's help.
public enum PanelHeaderActions {
    public static let dockLeft = "Dock on the left edge"
    public static let dockRight = "Dock on the right edge"
    public static let dragHelp = "Drag to the left or right edge of any display to pin Relay there"
}

/// Design/PanelHeader: the 44 pt bar on top of the list and the detail. Empty
/// header space is the drag surface; VoiceOver gets the two dock actions instead of the drag.
public struct PanelHeader<Content: View>: View {
    let onDock: (SidebarEdge) -> Void
    let content: Content

    public init(onDock: @escaping (SidebarEdge) -> Void, @ViewBuilder content: () -> Content) {
        self.onDock = onDock
        self.content = content()
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: DS.Space.inline) { content }
                .padding(.horizontal, DS.Space.gutter)
                .frame(height: DS.Metric.header)
                .background(DragHandle().help(PanelHeaderActions.dragHelp).accessibilityHidden(true))
                .background(DS.Color.bar)
                .accessibilityElement(children: .contain)
                .accessibilityAction(named: PanelHeaderActions.dockLeft) { onDock(.left) }
                .accessibilityAction(named: PanelHeaderActions.dockRight) { onDock(.right) }
            Divider()
        }
    }
}
