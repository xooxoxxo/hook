import SwiftUI

/// Design/ClosedGroupHeader: the Recently closed section's header, a CollapsibleHeader that
/// folds only its own section (⌥-click too; Collapse All never reaches it). The closed rows
/// are the section's own rows.
public struct ClosedGroupHeader: View {
    let count: Int
    @Binding var expanded: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(count: Int, expanded: Binding<Bool>) {
        self.count = count
        _expanded = expanded
    }

    public var body: some View {
        CollapsibleHeader(title: "Recently closed", count: count, collapsed: !expanded,
                          accessibilityLabel: Self.accessibilityText(count: count),
                          help: "Asks closed in the last 24 hours") { _ in
            withAnimation(DS.motion(DS.Motion.reveal, reduce: reduceMotion)) {
                expanded.toggle()
            }
        }
    }

    public static func accessibilityText(count: Int) -> String {
        "Recently closed, \(count) \(count == 1 ? "ask" : "asks")"
    }
}
