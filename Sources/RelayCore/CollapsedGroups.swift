import Foundation

/// The queue groups the owner collapsed, kept across launches as a JSON array of keys in
/// UserDefaults. A key names the grouping and the group (`project:<name>`, `urgency:<word>`),
/// so a project and an urgency word with the same text never share a state.
///
/// Recently closed is not a group here: it keeps its own `relay.closedToday.expanded` flag,
/// and Collapse All / Expand All never touch it.
public struct CollapsedGroups: Equatable, Sendable {
    /// The UserDefaults key holding the JSON array.
    public static let defaultsKey = "relay.queue.collapsedGroups"

    public private(set) var keys: Set<String>

    public init(keys: Set<String> = []) {
        self.keys = keys
    }

    /// Decodes a stored JSON array; anything unreadable is an empty set (every group open).
    public init(json: String) {
        let decoded = json.data(using: .utf8).flatMap { try? JSONDecoder().decode([String].self, from: $0) }
        keys = Set(decoded ?? [])
    }

    /// The sorted JSON array, so the same set always stores the same text.
    public var json: String {
        guard let data = try? JSONEncoder().encode(keys.sorted()), let text = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return text
    }

    /// `project:<raw project>` (the empty project is `project:`) or `urgency:<word>` in lower case.
    public static func key(_ header: QueueSection.Header) -> String {
        switch header {
        case .project(let project): "project:" + project
        case .urgency(let urgency): "urgency:" + urgency.word.lowercased()
        }
    }

    public func isCollapsed(_ header: QueueSection.Header) -> Bool {
        keys.contains(Self.key(header))
    }

    public mutating func set(_ header: QueueSection.Header, collapsed: Bool) {
        set(key: Self.key(header), collapsed: collapsed)
    }

    public mutating func set(key: String, collapsed: Bool) {
        if collapsed { keys.insert(key) } else { keys.remove(key) }
    }

    public mutating func toggle(_ header: QueueSection.Header) {
        set(header, collapsed: !isCollapsed(header))
    }

    /// Collapse All / Expand All over these groups (the ones on screen). Keys of groups that
    /// aren't listed (the other grouping, a project that has no asks now) keep their state.
    public mutating func setAll(_ headers: [QueueSection.Header], collapsed: Bool) {
        for header in headers { set(header, collapsed: collapsed) }
    }

    /// The headers of the sections that have one; a flat list has none.
    public static func headers(_ sections: [QueueSection]) -> [QueueSection.Header] {
        sections.compactMap(\.header)
    }

    /// Collapse All has something to do: a listed group is open.
    public func canCollapseAll(_ headers: [QueueSection.Header]) -> Bool {
        headers.contains { !isCollapsed($0) }
    }

    /// Expand All has something to do: a listed group is collapsed.
    public func canExpandAll(_ headers: [QueueSection.Header]) -> Bool {
        headers.contains { isCollapsed($0) }
    }

    /// A collapsed header's peek: the newest of the group's rows (latest `created`; an
    /// unreadable date counts as oldest, and ties keep the first in list order).
    public static func newest(_ rows: [AskRowModel]) -> AskRowModel? {
        rows.reduce(nil) { best, row in
            guard let best else { return row }
            return (row.createdDate ?? .distantPast) > (best.createdDate ?? .distantPast) ? row : best
        }
    }

    /// Reads, changes and writes back the stored set (PanelKeys, outside the view).
    public static func update(_ defaults: UserDefaults, _ change: (inout CollapsedGroups) -> Void) {
        var groups = CollapsedGroups(json: defaults.string(forKey: defaultsKey) ?? "[]")
        change(&groups)
        defaults.set(groups.json, forKey: defaultsKey)
    }
}
