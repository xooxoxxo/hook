import Foundation

/// The namespace for per-source UserDefaults keys (ticks, selection, filter).
/// A mailbox key includes the port, path and context, so two mailboxes on
/// one host, or one mailbox under two contexts, never share ticks.
public enum SourceKey {
    public static let none = "none"
    public static let local = "local"
    public static let migratedFlag = "relay.migrated.sourceKey.v2"

    public static func mailbox(_ settings: MailboxSettings) -> String {
        let url = settings.url
        let host = (url.host(percentEncoded: false) ?? "").lowercased()
        let port = url.port.map { ":\($0)" } ?? ""
        var path = url.path(percentEncoded: true)
        while path.hasSuffix("/") { path.removeLast() }
        return "mailbox:" + host + port + path + "#" + settings.context
    }

    /// 0.5's key, kept only to migrate from it.
    public static func legacyMailbox(_ settings: MailboxSettings) -> String {
        "mailbox:" + (settings.url.host() ?? "")
    }

    /// Once per Mac: copies `legacy`'s tick and selection keys into `current`'s namespace.
    public static func migrate(_ defaults: UserDefaults, from legacy: String, to current: String) {
        guard !defaults.bool(forKey: migratedFlag) else { return }
        defer { defaults.set(true, forKey: migratedFlag) }
        guard legacy != current else { return }
        let ticks = "relay.ticks." + legacy + "."
        for (key, value) in defaults.dictionaryRepresentation() where key.hasPrefix(ticks) {
            let id = String(key.dropFirst(ticks.count))
            guard !id.contains(".") else { continue }
            copy(value, to: TickStore.legacyKey(sourceKey: current, id: id), defaults)
        }
        if let selection = defaults.object(forKey: "relay.panel.selection." + legacy) {
            copy(selection, to: "relay.panel.selection." + current, defaults)
        }
    }

    private static func copy(_ value: Any, to key: String, _ defaults: UserDefaults) {
        guard defaults.object(forKey: key) == nil else { return }
        defaults.set(value, forKey: key)
    }
}

/// What the Store shows; a change swaps the source. `pollSeconds` isn't part of it:
/// a new interval only restarts the timer.
public struct SourceIdentity: Equatable, Sendable {
    public var key: String
    public var mailbox: MailboxSettings?

    public init(key: String, mailbox: MailboxSettings?) {
        self.key = key
        self.mailbox = mailbox
    }
}
