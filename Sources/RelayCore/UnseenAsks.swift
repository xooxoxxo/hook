import Foundation

/// The asks behind the menu-bar dot: those that arrived while the panel was hidden
/// and that the owner hasn't seen yet. Showing the panel marks everything seen; an
/// ask seen once never counts again. Kept in UserDefaults, so a relaunch keeps
/// unseen asks unseen.
public struct UnseenAsks: Sendable, Equatable {
    public static let defaultsKey = "relay.menubar.unseen"

    public private(set) var ids: Set<String>

    public init(ids: Set<String> = []) {
        self.ids = ids
    }

    /// True while any ask is unseen: the menu bar shows the dot.
    public var showsDot: Bool { !ids.isEmpty }

    /// New asks from the Store diff. Only a hidden panel leaves them unseen.
    public mutating func arrived(_ new: [String], panelVisible: Bool) {
        guard !panelVisible else { return }
        ids.formUnion(new)
    }

    /// The panel came on screen: everything open is seen.
    public mutating func panelShown() {
        ids.removeAll()
    }

    /// A closed (or vanished) ask no longer counts. Call only with a loaded list.
    public mutating func keep(open: Set<String>) {
        ids.formIntersection(open)
    }

    public static func load(_ defaults: UserDefaults) -> UnseenAsks {
        UnseenAsks(ids: Set(defaults.stringArray(forKey: defaultsKey) ?? []))
    }

    public func save(_ defaults: UserDefaults) {
        if ids.isEmpty {
            defaults.removeObject(forKey: Self.defaultsKey)
        } else {
            defaults.set(ids.sorted(), forKey: Self.defaultsKey)
        }
    }
}
