import RelayCore
import SwiftUI

/// Design/SectionHeader: a project or urgency group's header, a CollapsibleHeader with the
/// group's name and count; collapsed, its peek line names the group's newest ask. A click collapses or expands the group, ⌥-click every group;
/// its context menu has Collapse All and Expand All. The name is a project (or
/// "No project") or an urgency word.
public struct SectionHeader: View {
    let name: String
    let count: Int
    let collapsed: Bool
    let newest: Newest?
    let all: CollapseAllActions?
    let onToggle: (_ all: Bool) -> Void

    /// The group's newest ask: its title and compact age (RelativeAge.compact).
    public struct Newest: Equatable, Sendable {
        public let title: String
        public let age: String
        public init(title: String, age: String) {
            self.title = title
            self.age = age
        }
    }

    public init(name: String, count: Int, collapsed: Bool = false, newest: Newest? = nil, all: CollapseAllActions? = nil,
                onToggle: @escaping (_ all: Bool) -> Void = { _ in }) {
        self.name = name
        self.count = count
        self.collapsed = collapsed
        self.newest = newest
        self.all = all
        self.onToggle = onToggle
    }

    public var body: some View {
        CollapsibleHeader(title: Self.displayName(name), count: count, collapsed: collapsed,
                          peek: newest.map { CollapsibleHeader.peekText(title: $0.title, age: $0.age) },
                          accessibilityLabel: Self.accessibilityText(name: name, count: count,
                                                                     newest: collapsed ? newest : nil),
                          help: Self.help(collapsed: collapsed), onToggle: onToggle)
            .contextMenu {
                if let all { CollapseAllItems(all) }
            }
    }

    public static func displayName(_ name: String) -> String { name.isEmpty ? "No project" : line(name) }

    /// "Acme, 3 asks"; collapsed, with the newest ask: "Acme, 3 asks, newest: Rotate the key, 3 h".
    public static func accessibilityText(name: String, count: Int, newest: Newest? = nil) -> String {
        let base = "\(displayName(name)), \(count) \(count == 1 ? "ask" : "asks")"
        guard let newest else { return base }
        return base + ", newest: \(line(newest.title)), \(newest.age)"
    }

    public static func help(collapsed: Bool) -> String {
        (collapsed ? "Expand" : "Collapse") + " · ⌥-click for every group"
    }
}
