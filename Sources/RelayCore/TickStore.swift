import Foundation

/// Ticked items per source and ask: `relay.ticks.v2.<sourceKey>.<askId>`
/// holds `[path: fingerprint]`, one entry per ticked item (Flow.items: the leaves, and a
/// parent's own question, which only an optional parent's tick marks). A parent's done
/// state is otherwise derived from its sub-steps, never stored.
///
/// An ask whose steps all carry ids (Pond 1.1.0) uses `relay.ticks.v3.<sourceKey>.<askId>`
/// instead: `[stepID: contentHash]`, so a tick follows its step when a correction moves it and
/// drops when a correction changes any field of it.
public enum TickStore {
    public static let prefix = "relay.ticks.v2."
    public static let prefixV3 = "relay.ticks.v3."

    /// First authoritative 1.5 fetch retires this source's device-local ticks.
    /// Never upload them: an old cache could undo another device's untick.
    public static func adoptShared(_ defaults: UserDefaults, sourceKey: String) {
        let marker = "relay.ticks.shared." + sourceKey
        guard !defaults.bool(forKey: marker) else { return }
        let prefixes = [prefix, prefixV3, "relay.ticks."].map { $0 + sourceKey + "." }
        for key in defaults.dictionaryRepresentation().keys {
            guard let prefix = prefixes.first(where: key.hasPrefix) else { continue }
            if !key.dropFirst(prefix.count).contains(".") { defaults.removeObject(forKey: key) }
        }
        defaults.set(true, forKey: marker)
    }

    public static func key(sourceKey: String, id: String) -> String {
        prefix + sourceKey + "." + id
    }

    public static func keyV3(sourceKey: String, id: String) -> String {
        prefixV3 + sourceKey + "." + id
    }

    /// Every step and sub-step has an id (Verify always has "@verify").
    static func usesIDs(_ nodes: [DetailModel.Node]) -> Bool {
        !nodes.isEmpty && Flow.flattened(nodes).allSatisfy { $0.stepID != nil }
    }

    /// Called when the detail model is built, so the first frame is right. An entry
    /// whose leaf still has its fingerprint stays; else it moves to the one unticked
    /// leaf elsewhere with that fingerprint; else it is dropped. Changes are written back.
    /// With a v2 key, any v1 key for the ask is deleted, so unticking everything (which
    /// removes the v2 key) can't bring the 0.5 ticks back on the next load.
    public static func load(_ defaults: UserDefaults, sourceKey: String, id: String, nodes: [DetailModel.Node]) -> Set<String> {
        if usesIDs(nodes) { return loadV3(defaults, sourceKey: sourceKey, id: id, nodes: nodes) }
        let key = key(sourceKey: sourceKey, id: id)
        guard let stored = defaults.dictionary(forKey: key) as? [String: String] else {
            return migrateV1(defaults, sourceKey: sourceKey, id: id, nodes: nodes) ?? []
        }
        defaults.removeObject(forKey: legacyKey(sourceKey: sourceKey, id: id))
        let leaves = Flow.items(of: nodes)
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
        if usesIDs(nodes) {
            var entries: [String: String] = [:]
            for item in Flow.items(of: nodes) where ticks.contains(item.path) {
                if let stepID = item.stepID { entries[stepID] = item.contentHash }
            }
            write(defaults, keyV3(sourceKey: sourceKey, id: id), entries)
            return
        }
        var entries: [String: String] = [:]
        for leaf in Flow.items(of: nodes) where ticks.contains(leaf.path) {
            entries[leaf.path] = leaf.fingerprint
        }
        write(defaults, key(sourceKey: sourceKey, id: id), entries)
    }

    /// Removes this source's v2 keys whose id isn't in `ids`. Ids never contain ".",
    /// so a remainder with a dot belongs to another source whose key starts the same way.
    public static func prune(_ defaults: UserDefaults, sourceKey: String, keep ids: Set<String>) {
        let owners = [prefix + sourceKey + ".", prefixV3 + sourceKey + "."]
        for key in defaults.dictionaryRepresentation().keys {
            guard let own = owners.first(where: key.hasPrefix) else { continue }
            let id = String(key.dropFirst(own.count))
            if !id.contains("."), !ids.contains(id) {
                defaults.removeObject(forKey: key)
            }
        }
    }

    /// The v3 ticks as paths: an entry whose step still has its content hash stays, any other
    /// is dropped. With no v3 key, a v2 key migrates: each entry whose fingerprint matches the
    /// node at its path becomes `[stepID: contentHash]`, and the v2 key (and any v1 key) goes.
    static func loadV3(_ defaults: UserDefaults, sourceKey: String, id: String, nodes: [DetailModel.Node]) -> Set<String> {
        let key = keyV3(sourceKey: sourceKey, id: id)
        let items = Flow.items(of: nodes)
        guard var stored = defaults.dictionary(forKey: key) as? [String: String] else {
            let v2 = TickStore.key(sourceKey: sourceKey, id: id)
            let old = defaults.dictionary(forKey: v2) as? [String: String]
            let v1 = old == nil ? migrateV1(defaults, sourceKey: sourceKey, id: id, nodes: nodes, write: false) : nil
            defaults.removeObject(forKey: v2)
            defaults.removeObject(forKey: legacyKey(sourceKey: sourceKey, id: id))
            var entries: [String: String] = [:]
            for item in items {
                let matches = old.map { $0[item.path] == item.fingerprint } ?? (v1?.contains(item.path) ?? false)
                if matches, let stepID = item.stepID { entries[stepID] = item.contentHash }
            }
            write(defaults, key, entries)
            return Set(items.filter { $0.stepID.map { entries[$0] != nil } ?? false }.map(\.path))
        }
        let originallyStored = stored
        // Migrate the old synthetic Verify key only when no real step owns it.
        // An ambiguous old collision is discarded instead of transferring a tick.
        if !items.contains(where: { !$0.isVerify && $0.stepID == "verify" }),
           stored[SharedProgress.verifyID] == nil, let old = stored.removeValue(forKey: "verify") {
            stored[SharedProgress.verifyID] = old
        }
        var kept: [String: String] = [:]
        var ticks: Set<String> = []
        for item in items {
            guard let stepID = item.stepID, stored[stepID] == item.contentHash else { continue }
            kept[stepID] = item.contentHash
            ticks.insert(item.path)
        }
        if kept != originallyStored { write(defaults, key, kept) }
        return ticks
    }

    private static func write(_ defaults: UserDefaults, _ key: String, _ entries: [String: String]) {
        if entries.isEmpty {
            defaults.removeObject(forKey: key)
        } else {
            defaults.set(entries, forKey: key)
        }
    }
}

extension TickStore {
    /// The 0.5 key: sorted `[Int]` of 0-based node indices (steps, then verify).
    public static func legacyKey(sourceKey: String, id: String) -> String {
        "relay.ticks." + sourceKey + "." + id
    }

    /// nil without a v1 key. Otherwise the v1 key is deleted and its ticks written as
    /// v2: index i < steps → step i+1 (every sub-step when the step now has them);
    /// i == steps with a verify → verify. Any index out of range migrates nothing.
    static func migrateV1(_ defaults: UserDefaults, sourceKey: String, id: String, nodes: [DetailModel.Node],
                          write: Bool = true) -> Set<String>? {
        let old = legacyKey(sourceKey: sourceKey, id: id)
        guard let indices = defaults.array(forKey: old) as? [Int] else { return nil }
        defaults.removeObject(forKey: old)
        let steps = nodes.filter { !$0.isVerify }
        let verify = nodes.first(where: \.isVerify)
        var ticks: Set<String> = []
        for index in indices {
            if index >= 0, index < steps.count {
                let step = steps[index]
                if step.isParent { ticks.formUnion(step.children.map(\.path)) } else { ticks.insert(step.path) }
            } else if index == steps.count, let verify {
                ticks.insert(verify.path)
            } else {
                return []
            }
        }
        if write { save(defaults, sourceKey: sourceKey, id: id, ticks: ticks, nodes: nodes) }
        return ticks
    }
}
