import Foundation

/// The ordinary windows Hook has open (document viewers, Settings), counted so the app
/// shows a Dock icon, is in ⌘-Tab and cycles with ⌘-` while any is open, and goes back
/// to a menu-bar-only app when the last one closes. Pure: `AppPresence` applies it.
public struct StandardWindows: Sendable, Equatable {
    /// What the app's activation policy should become.
    public enum Change: Sendable, Equatable {
        /// The first window opened: a regular app (Dock icon, ⌘-Tab).
        case regular
        /// The last window closed: back to the menu bar only.
        case accessory
    }

    private(set) public var open: Set<ObjectIdentifier> = []

    public init() {}

    public var isEmpty: Bool { open.isEmpty }

    /// `window` opened (or was shown again). `.regular` for the first one; nil when it
    /// was already counted or others are open.
    public mutating func opened(_ window: ObjectIdentifier) -> Change? {
        let wasEmpty = open.isEmpty
        guard open.insert(window).inserted else { return nil }
        return wasEmpty ? .regular : nil
    }

    /// `window` closed. `.accessory` when it was the last one; nil when it wasn't counted
    /// or others are still open.
    public mutating func closed(_ window: ObjectIdentifier) -> Change? {
        guard open.remove(window) != nil else { return nil }
        return open.isEmpty ? .accessory : nil
    }
}
