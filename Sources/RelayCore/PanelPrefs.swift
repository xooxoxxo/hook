import Foundation

/// Panel view state that survives a relaunch. UserDefaults, not
/// config.json: no other tool reads it. Never pruned.
public enum PanelPrefs {
    public static let groupingKey = "relay.queue.grouping"

    public static func filterKey(sourceKey: String) -> String { "relay.queue.filter." + sourceKey }
    public static func selectionKey(sourceKey: String) -> String { "relay.panel.selection." + sourceKey }

    public static func grouping(_ defaults: UserDefaults) -> QueueGrouping {
        QueueGrouping(stored: defaults.string(forKey: groupingKey))
    }

    public static func setGrouping(_ grouping: QueueGrouping, _ defaults: UserDefaults) {
        defaults.set(grouping.rawValue, forKey: groupingKey)
    }

    /// The raw project string, exactly as `WireItem.projectId` holds it.
    public static func filter(_ defaults: UserDefaults, sourceKey: String) -> String? {
        defaults.string(forKey: filterKey(sourceKey: sourceKey))
    }

    public static func setFilter(_ project: String?, _ defaults: UserDefaults, sourceKey: String) {
        set(project, filterKey(sourceKey: sourceKey), defaults)
    }

    public static func selection(_ defaults: UserDefaults, sourceKey: String) -> String? {
        defaults.string(forKey: selectionKey(sourceKey: sourceKey))
    }

    public static func setSelection(_ id: String?, _ defaults: UserDefaults, sourceKey: String) {
        set(id, selectionKey(sourceKey: sourceKey), defaults)
    }

    private static func set(_ value: String?, _ key: String, _ defaults: UserDefaults) {
        if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
    }
}
