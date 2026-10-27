import Foundation

/// Where the menu-bar icon starts out. macOS lays status items out by launch order and
/// puts one without a saved position at the far left, so each relaunch (an update, a
/// restart) moved Hook's icon there, where a crowded menu bar hides it behind the
/// notch. Seeding a position near the right once fixes that; the user's own ⌘-drag
/// writes the same key and replaces the seed.
public enum StatusItemPosition {
    /// The key macOS reads for the app's first status item, which has no autosave name.
    public static let key = "NSStatusItem Preferred Position Item-0"
    /// Points from the right edge of the menu bar: left of the system items, clear of the notch.
    public static let seed: Double = 280

    /// Writes the seed only when no position is saved yet.
    public static func seedIfNeeded(_ defaults: UserDefaults) {
        if defaults.object(forKey: key) == nil {
            defaults.set(seed, forKey: key)
        }
    }
}
