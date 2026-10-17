import Foundation

/// Ticked leaves per source and ask (design §8): `relay.ticks.v2.<sourceKey>.<askId>`
/// holds `[path: fingerprint]`, one entry per ticked leaf. Parents are derived, never stored.
public enum TickStore {
    public static let prefix = "relay.ticks.v2."

    public static func key(sourceKey: String, id: String) -> String {
        prefix + sourceKey + "." + id
    }

    /// Called when the detail model is built, so the first frame is right. An entry
    /// whose leaf still has its fingerprint stays; else it moves to the one unticked
    /// leaf elsewhere with that fingerprint; else it is dropped. Changes are written back.
    public static func load(_ defaults: UserDefaults, sourceKey: String, id: String, nodes: [DetailModel.Node]) -> Set<String> {
        let key = key(sourceKey: sourceKey, id: id)
        guard let stored = defaults.dictionary(forKey: key) as? [String: String] else { return [] }
        let leaves = Flow.leaves(of: nodes)
        var byPath: [String: String] = [:]
        for leaf in leaves { byPath[leaf.path] = leaf.fingerprint }

        var ticked: [String: String] = [:]
        var unmatched: [String] = []
        for (path, fingerprint) in stored.sorted(by: { $0.key < $1.key }) {
            if byPath[path] == fingerprint {
                ticked[path] = fingerprint
            } else {
                unmatched.append(fingerprint)
            }
        }
        for fingerprint in unmatched {
            let candidates = leaves.filter { $0.fingerprint == fingerprint && ticked[$0.path] == nil }
            if candidates.count == 1 { ticked[candidates[0].path] = fingerprint }
        }
        if ticked != stored { write(defaults, key, ticked) }
        return Set(ticked.keys)
    }

    public static func save(_ defaults: UserDefaults, sourceKey: String, id: String, ticks: Set<String>, nodes: [DetailModel.Node]) {
        var entries: [String: String] = [:]
        for leaf in Flow.leaves(of: nodes) where ticks.contains(leaf.path) {
            entries[leaf.path] = leaf.fingerprint
        }
        write(defaults, key(sourceKey: sourceKey, id: id), entries)
    }

    /// Removes this source's v2 keys whose id isn't in `ids`. Ids never contain ".",
    /// so a remainder with a dot belongs to another source whose key starts the same way.
    public static func prune(_ defaults: UserDefaults, sourceKey: String, keep ids: Set<String>) {
        let own = prefix + sourceKey + "."
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(own) {
            let id = String(key.dropFirst(own.count))
            if !id.contains("."), !ids.contains(id) {
                defaults.removeObject(forKey: key)
            }
        }
    }

    private static func write(_ defaults: UserDefaults, _ key: String, _ entries: [String: String]) {
        if entries.isEmpty {
            defaults.removeObject(forKey: key)
        } else {
            defaults.set(entries, forKey: key)
        }
    }
}
