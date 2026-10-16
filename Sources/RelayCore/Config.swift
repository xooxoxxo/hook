import Foundation

public enum ConfigError: Error, Sendable, LocalizedError {
    case missing(String)
    case invalid(String)
    case unreadableToken(String)

    public var errorDescription: String? {
        switch self {
        case .missing(let path):
            return "No Relay config at \(path). Run scripts/install.sh."
        case .invalid(let what):
            return "Invalid Relay config: \(what)"
        case .unreadableToken(let path):
            return "Token file is missing or empty: \(path)"
        }
    }
}

public enum SourceKind: String, Sendable, Equatable, Codable {
    case local
    case mailbox
}

public enum SidebarEdge: String, Sendable, Equatable, Codable {
    case right
    case left
}

public enum AppearanceSetting: String, Sendable, Equatable, Codable {
    case system
    case light
    case dark
}

/// `notify` in config.json: which urgencies notify, and how.
public struct NotifySettings: Sendable, Equatable, Codable {
    public var now: Bool
    public var today: Bool
    public var whenever: Bool
    public var sound: Bool
    public var slideIn: Bool

    enum CodingKeys: String, CodingKey {
        case now, today, whenever, sound, slideIn
    }

    public init(now: Bool = true, today: Bool = true, whenever: Bool = false, sound: Bool = false, slideIn: Bool = true) {
        self.now = now
        self.today = today
        self.whenever = whenever
        self.sound = sound
        self.slideIn = slideIn
    }

    /// Each missing or wrong-typed key takes its default.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = NotifySettings()
        now = c.lenient(Bool.self, .now) ?? d.now
        today = c.lenient(Bool.self, .today) ?? d.today
        whenever = c.lenient(Bool.self, .whenever) ?? d.whenever
        sound = c.lenient(Bool.self, .sound) ?? d.sound
        slideIn = c.lenient(Bool.self, .slideIn) ?? d.slideIn
    }
}

/// The resolved mailbox fields. Holds the token file's path, never the token.
public struct MailboxSettings: Sendable, Equatable {
    public let url: URL
    public let tokenFile: String
    public let context: String

    public init(url: URL, tokenFile: String, context: String) {
        self.url = url
        self.tokenFile = tokenFile
        self.context = context
    }

    /// Reads the bearer token at use time. The value is never logged or stored.
    public func readToken() throws -> String {
        let path = (tokenFile as NSString).expandingTildeInPath
        let raw = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw ConfigError.unreadableToken(path) }
        return token
    }
}

/// Which queue the config points at.
public enum ResolvedSource: Sendable, Equatable {
    case local
    case mailbox(MailboxSettings)
    /// No `source` and no `mailboxURL`: the app shows Welcome.
    case incomplete
    /// A config error, reported like invalid JSON.
    case invalid(String)
}

/// `~/.config/relay/config.json`. Holds the token file's path, never the token.
public struct RelayConfig: Decodable, Sendable, Equatable {
    public static let defaultPort = 47823
    public static let defaultPollSeconds = 15
    public static let defaultKeepDays = 14
    public static let defaultContext = "personal"
    static let mailboxProblem = "mailbox needs an http(s) mailboxURL and a tokenFile"

    public var source: SourceKind?
    public var mailboxURL: String?
    public var tokenFile: String?
    /// Sent as `context` on every mailbox POST /asks.
    public var context: String
    public var port: Int
    public var pollSeconds: Int
    /// Global show/hide shortcut, e.g. "ctrl+opt+cmd+r"; "" disables it.
    public var hotkey: String
    /// Local mode: days a finished ask is kept.
    public var keepDays: Int
    public var showCount: Bool
    public var sidebarEdge: SidebarEdge
    public var appearance: AppearanceSetting
    public var notify: NotifySettings
    /// Away mode: Automatic, or set to Home or Away.
    public var presence: PresenceMode
    /// Automatic: minutes without input before Relay marks the owner away;
    /// one of `PresenceLogic.awayAfterChoices`.
    public var awayAfterMinutes: Int
    /// Written by install.sh; the Connect tab builds commands from it.
    public var repoPath: String?
    /// The UUID of the display the sidebar is pinned to; set by dragging the
    /// panel. nil, or a display that isn't connected, means the main display.
    public var sidebarDisplay: String?

    enum CodingKeys: String, CodingKey {
        case source, mailboxURL, tokenFile, context, port, pollSeconds, hotkey, keepDays
        case showCount, sidebarEdge, appearance, notify, presence, awayAfterMinutes, repoPath
        case sidebarDisplay
    }

    public init(
        source: SourceKind? = nil,
        mailboxURL: String? = nil,
        tokenFile: String? = nil,
        context: String = RelayConfig.defaultContext,
        port: Int = RelayConfig.defaultPort,
        pollSeconds: Int = RelayConfig.defaultPollSeconds,
        hotkey: String = HotkeySpec.defaultString,
        keepDays: Int = RelayConfig.defaultKeepDays,
        showCount: Bool = true,
        sidebarEdge: SidebarEdge = .right,
        appearance: AppearanceSetting = .system,
        notify: NotifySettings = NotifySettings(),
        presence: PresenceMode = .auto,
        awayAfterMinutes: Int = PresenceLogic.defaultAwayAfterMinutes,
        repoPath: String? = nil,
        sidebarDisplay: String? = nil
    ) {
        self.source = source
        self.mailboxURL = mailboxURL
        self.tokenFile = tokenFile
        self.context = context
        self.port = port
        self.pollSeconds = pollSeconds
        self.hotkey = hotkey
        self.keepDays = keepDays
        self.showCount = showCount
        self.sidebarEdge = sidebarEdge
        self.appearance = appearance
        self.notify = notify
        self.presence = presence
        self.awayAfterMinutes = awayAfterMinutes
        self.repoPath = repoPath
        self.sidebarDisplay = sidebarDisplay
    }

    /// A missing, null, wrong-typed or out-of-range key takes its default.
    /// Only a port that isn't an integer in 1...65535 throws.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        source = c.lenient(String.self, .source).flatMap(SourceKind.init(rawValue:))
        mailboxURL = c.lenient(String.self, .mailboxURL)
        tokenFile = c.lenient(String.self, .tokenFile)
        context = c.lenient(String.self, .context) ?? Self.defaultContext
        if c.contains(.port), try !c.decodeNil(forKey: .port) {
            guard let port = try? c.decode(Int.self, forKey: .port), (1...65535).contains(port) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .port, in: c, debugDescription: "port must be a whole number from 1 to 65535")
            }
            self.port = port
        } else {
            port = Self.defaultPort
        }
        pollSeconds = c.lenient(Int.self, .pollSeconds).flatMap { $0 >= 1 ? $0 : nil } ?? Self.defaultPollSeconds
        hotkey = c.lenient(String.self, .hotkey) ?? HotkeySpec.defaultString
        keepDays = c.lenient(Int.self, .keepDays).flatMap { (1...365).contains($0) ? $0 : nil } ?? Self.defaultKeepDays
        showCount = c.lenient(Bool.self, .showCount) ?? true
        sidebarEdge = c.lenient(String.self, .sidebarEdge).flatMap(SidebarEdge.init(rawValue:)) ?? .right
        appearance = c.lenient(String.self, .appearance).flatMap(AppearanceSetting.init(rawValue:)) ?? .system
        notify = c.lenient(NotifySettings.self, .notify) ?? NotifySettings()
        presence = c.lenient(String.self, .presence).flatMap(PresenceMode.init(rawValue:)) ?? .auto
        awayAfterMinutes = c.lenient(Int.self, .awayAfterMinutes)
            .flatMap { PresenceLogic.awayAfterChoices.contains($0) ? $0 : nil } ?? PresenceLogic.defaultAwayAfterMinutes
        repoPath = c.lenient(String.self, .repoPath)
        sidebarDisplay = c.lenient(String.self, .sidebarDisplay).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// `source` when present; else mailbox when `mailboxURL` is present; else incomplete.
    /// A mailbox needs an http(s) URL with a host and a non-empty `tokenFile`.
    public func resolvedSource() -> ResolvedSource {
        guard let kind = source ?? (mailboxURL != nil ? .mailbox : nil) else { return .incomplete }
        switch kind {
        case .local:
            return .local
        case .mailbox:
            guard let raw = mailboxURL, let url = URL(string: raw),
                  let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
                  let host = url.host(), !host.isEmpty,
                  let tokenFile, !tokenFile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .invalid(Self.mailboxProblem)
            }
            return .mailbox(MailboxSettings(url: url, tokenFile: tokenFile, context: context))
        }
    }

    /// `$RELAY_CONFIG` when set, else `~/.config/relay/config.json`.
    public static func path(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let custom = environment["RELAY_CONFIG"], !custom.isEmpty {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".config/relay/config.json")
    }

    /// The directories Relay owns and tightens to 0700 at launch even when they
    /// already exist: the default `~/.config/relay` and the data directory. The
    /// folder holding a custom `$RELAY_CONFIG` is only created when missing.
    public static func ownedDirectories(configURL: URL, dataDirectory: URL) -> (tighten: [URL], createOnly: [URL]) {
        let configDirectory = configURL.deletingLastPathComponent()
        let defaultDirectory = path(environment: [:]).deletingLastPathComponent()
        if configDirectory.standardizedFileURL.path == defaultDirectory.standardizedFileURL.path {
            return ([configDirectory, dataDirectory], [])
        }
        return ([dataDirectory], [configDirectory])
    }

    /// The config file's directory; `local-token` and `replies-cursor.json` live here.
    public static func directory(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        path(environment: environment).deletingLastPathComponent()
    }

    /// `ConfigError.missing` when the file can't be read; `.invalid(reason)`
    /// when it isn't a JSON object or has a bad port. The reason never quotes the file.
    public static func load(from url: URL) throws -> RelayConfig {
        guard let data = try? Data(contentsOf: url) else {
            throw ConfigError.missing(url.path)
        }
        return try decode(data)
    }

    static func decode(_ data: Data) throws -> RelayConfig {
        guard let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            throw ConfigError.invalid("not valid JSON")
        }
        guard object is [String: Any] else {
            throw ConfigError.invalid("not a JSON object")
        }
        do {
            return try JSONDecoder().decode(RelayConfig.self, from: data)
        } catch DecodingError.dataCorrupted(let context) {
            throw ConfigError.invalid(context.debugDescription)
        } catch {
            throw ConfigError.invalid("can't be decoded")
        }
    }
}

extension KeyedDecodingContainer {
    /// The value when present and of the right type; nil when absent, null or wrong-typed.
    func lenient<T: Decodable>(_ type: T.Type, _ key: Key) -> T? {
        (try? decodeIfPresent(type, forKey: key)) ?? nil
    }
}
