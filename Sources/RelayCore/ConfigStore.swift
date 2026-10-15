import Foundation

/// The outcome of reading config.json.
public enum ConfigLoad: Sendable, Equatable {
    case missing
    /// The file exists but can't be used; the text says why, never what it holds.
    case unreadable(String)
    case loaded(RelayConfig)
}

/// Reads and merge-saves config.json.
public enum ConfigStore {
    public static func load(_ url: URL) -> ConfigLoad {
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        do {
            try PrivateFile.checkTrusted(directory: url.deletingLastPathComponent())
            try PrivateFile.checkTrusted(file: url)
        } catch {
            return .unreadable(error.localizedDescription)
        }
        do {
            return .loaded(try RelayConfig.load(from: url))
        } catch ConfigError.invalid(let reason) {
            return .unreadable(reason)
        } catch {
            return .unreadable("can't be read")
        }
    }

    /// An absent file is {}. A file that exists but isn't a JSON object → throws ConfigError.invalid and writes nothing.
    /// Applies `set`, then `remove`, keeps every other key, writes pretty-printed with sorted keys via PrivateFile.write.
    @discardableResult
    public static func merge(set: [String: Any], remove: [String] = [], into url: URL) throws -> Data {
        var object: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: url.path) {
            guard let data = try? Data(contentsOf: url) else {
                throw ConfigError.invalid("can't be read")
            }
            guard let parsed = try? JSONSerialization.jsonObject(with: data),
                  let existing = parsed as? [String: Any] else {
                throw ConfigError.invalid("config.json isn't a JSON object, so it was left unchanged")
            }
            object = existing
        }
        for (key, value) in set {
            object[key] = value
        }
        for key in remove {
            object.removeValue(forKey: key)
        }
        guard JSONSerialization.isValidJSONObject(object) else {
            throw ConfigError.invalid("a setting isn't a JSON value")
        }
        var data = try JSONSerialization.data(
            withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        data.append(0x0A)
        try PrivateFile.write(data, to: url)
        return data
    }
}

/// What to use after a reload.
public enum ConfigReload {
    /// .loaded(c) → (c, nil)
    /// .unreadable(m) → (lastGood, "config.json has an error: \(m)")
    /// .missing → (lastGood, "config.json is missing")
    public static func next(lastGood: RelayConfig?, load: ConfigLoad) -> (config: RelayConfig?, note: String?) {
        switch load {
        case .loaded(let config):
            return (config, nil)
        case .unreadable(let message):
            return (lastGood, "config.json has an error: \(message)")
        case .missing:
            return (lastGood, "config.json is missing")
        }
    }
}
