#if os(macOS)
import AppKit
#endif
import RelayCore
import SwiftUI

/// Design/CollapsibleHeader: a queue section header that is one full-width button. A click
/// collapses or expands its group; `onToggle` is told whether ⌥ was held (all groups).
/// There is no chevron. Expanded: the name in plain `secondary`. Collapsed ("peek line"):
/// the name in semibold `primary`, and under it, when given, one `secondary` line naming the
/// group's newest ask. The count pill sits on the right either way. The collapsed look lives
/// only here, behind `collapsed`, so it can change in one place.
///
/// The Section it heads must be `.collapsible(false)`: a collapsible sidebar section gets
/// AppKit's own disclosure button over the header's trailing end, which takes the click.
public struct CollapsibleHeader: View {
    let title: String
    let count: Int
    let collapsed: Bool
    let peek: String?
    let accessibilityLabel: String
    let help: String
    let onToggle: (_ all: Bool) -> Void

    public init(title: String, count: Int, collapsed: Bool, peek: String? = nil, accessibilityLabel: String, help: String,
                onToggle: @escaping (_ all: Bool) -> Void) {
        self.title = title
        self.count = count
        self.collapsed = collapsed
        self.peek = peek
        self.accessibilityLabel = accessibilityLabel
        self.help = help
        self.onToggle = onToggle
    }

    public var body: some View {
        Button {
            #if os(macOS)
            onToggle(NSEvent.modifierFlags.contains(.option))
            #else
            onToggle(false)
            #endif
        } label: {
            HStack(alignment: .center, spacing: DS.Space.inline) {
                VStack(alignment: .leading, spacing: DS.Space.headerPeek) {
                    Text(title)
                        .fontWeight(collapsed ? .semibold : nil)
                        .foregroundStyle(collapsed ? DS.Color.primary : DS.Color.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .alignmentProbe(.gutterText)
                    if collapsed, let peek {
                        Text(peek)
                            .font(DS.Font.caption)
                            .foregroundStyle(DS.Color.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                Spacer(minLength: DS.Space.inline)
                CountPill(count: count)
                    .alignmentProbe(.trailingEdge, measure: .frame)
            }
            .padding(.vertical, DS.Space.sectionHeaderV)
            .padding(.leading, DS.Space.sectionHeaderLead)
            .padding(.trailing, DS.Space.gutter - DS.Space.sectionHeaderLead)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(Self.accessibilityValue(collapsed: collapsed))
        .accessibilityAddTraits(.isHeader)
    }

    /// "Collapsed" or "Expanded", as every disclosure in Hook says it.
    public static func accessibilityValue(collapsed: Bool) -> String {
        TrailingDisclosureStyle.value(expanded: !collapsed)
    }

    /// The peek line: "Newest: <title> · <compact age>".
    public static func peekText(title: String, age: String) -> String {
        "Newest: \(line(title)) · \(age)"
    }
}

/// Collapse All / Expand All over the queue's groups (never Recently closed), for the queue
/// menu and a group header's context menu.
public struct CollapseAllActions {
    public let canCollapse: Bool
    public let canExpand: Bool
    /// true collapses every group, false expands every group.
    public let setAll: (_ collapsed: Bool) -> Void

    public init(canCollapse: Bool, canExpand: Bool, setAll: @escaping (_ collapsed: Bool) -> Void) {
        self.canCollapse = canCollapse
        self.canExpand = canExpand
        self.setAll = setAll
    }
}

/// The two menu items, each disabled when it has nothing to do.
public struct CollapseAllItems: View {
    let actions: CollapseAllActions

    public init(_ actions: CollapseAllActions) {
        self.actions = actions
    }

    public var body: some View {
        Button("Collapse All") { actions.setAll(true) }
            .disabled(!actions.canCollapse)
        Button("Expand All") { actions.setAll(false) }
            .disabled(!actions.canExpand)
    }
}
