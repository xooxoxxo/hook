import Foundation

// MARK: Tabs

extension SettingsTabID {
    public static let defaultsKey = "relay.settings.tabID"
    /// 0.5.x saved the tab here, as an index (0–3) or a raw value.
    public static let legacyDefaultsKey = "relay.settings.tab"
    static let legacyOrder: [SettingsTabID] = [.general, .queue, .notifications, .connect]

    /// The tab Settings opens on. A legacy value is migrated once: written as an id, then deleted.
    public static func restore(_ defaults: UserDefaults) -> SettingsTabID {
        if let raw = defaults.string(forKey: defaultsKey), let tab = SettingsTabID(rawValue: raw) {
            defaults.removeObject(forKey: legacyDefaultsKey)
            return tab
        }
        guard let legacy = defaults.object(forKey: legacyDefaultsKey) else { return .general }
        defaults.removeObject(forKey: legacyDefaultsKey)
        let tab: SettingsTabID
        if let raw = legacy as? String {
            tab = SettingsTabID(rawValue: raw) ?? .general
        } else if let index = legacy as? Int, legacyOrder.indices.contains(index) {
            tab = legacyOrder[index]
        } else {
            tab = .general
        }
        tab.save(defaults)
        return tab
    }

    public func save(_ defaults: UserDefaults) {
        defaults.set(rawValue, forKey: Self.defaultsKey)
    }

    /// ⌘1 … ⌘5, left to right.
    public init?(shortcutDigit: Int) {
        guard (1...Self.allCases.count).contains(shortcutDigit) else { return nil }
        self = Self.allCases[shortcutDigit - 1]
    }

    public var title: String {
        switch self {
        case .general: "General"
        case .panel: "Panel"
        case .queue: "Queue"
        case .notifications: "Notifications"
        case .connect: "Connect"
        }
    }

    public var symbol: String {
        switch self {
        case .general: "gearshape"
        case .panel: "sidebar.right"
        case .queue: "tray"
        case .notifications: "bell"
        case .connect: "link"
        }
    }
}

// MARK: Snapshot parts

/// Why the global shortcut isn't working (§4.8); a red caption under the recorder.
public enum ShortcutProblem: Equatable, Sendable {
    case unsupportedKey, refused, resumeFailed

    public var text: String {
        switch self {
        case .unsupportedKey: "That key can't be used. Pick a letter, a digit, Space, ` or F1–F12."
        case .refused: "macOS refused this shortcut. Another app may be using it."
        case .resumeFailed: "The shortcut was turned off because macOS refused it again. Record it again."
        }
    }
}

/// One entry of Settings → Panel → Display; id nil is "Main display".
public struct DisplayOption: Equatable, Sendable, Identifiable {
    public var id: String?
    public var title: String
    public var connected: Bool
    public init(id: String?, title: String, connected: Bool) {
        self.id = id
        self.title = title
        self.connected = connected
    }
}

public struct LoginState: Equatable, Sendable {
    public var on: Bool
    public var error: String?
    public var needsApproval: Bool
    public init(on: Bool = false, error: String? = nil, needsApproval: Bool = false) {
        self.on = on
        self.error = error
        self.needsApproval = needsApproval
    }
}

/// What Settings → Connect shows, read from `repoPath` and the home folder.
public struct RepoState: Equatable, Sendable {
    public var repoPath: String?
    public var mcpCommand: String?
    public var claudeMdAvailable: Bool
    public var skill: ConnectInfo.SkillState?
    public var cliFound: Bool
    public var lastCall: Date?
    public init(repoPath: String? = nil, mcpCommand: String? = nil, claudeMdAvailable: Bool = false,
                skill: ConnectInfo.SkillState? = nil, cliFound: Bool = false, lastCall: Date? = nil) {
        self.repoPath = repoPath
        self.mcpCommand = mcpCommand
        self.claudeMdAvailable = claudeMdAvailable
        self.skill = skill
        self.cliFound = cliFound
        self.lastCall = lastCall
    }
}

/// The Mailbox fields as typed, before Connect saves them. Memory only.
public struct MailboxDraft: Equatable, Sendable {
    public var address: String
    public var tokenFile: String
    public var context: String
    public init(address: String = "", tokenFile: String = "", context: String = "") {
        self.address = address
        self.tokenFile = tokenFile
        self.context = context
    }
}

/// Settings → Queue → Send a Test Ask.
public enum TestAskResult: Equatable, Sendable {
    case sent(id: String)
    case alreadyWaiting(id: String)
    case failed(String)
}

/// Everything a Settings or Welcome view reads, as values.
public struct SettingsSnapshot: Equatable {
    public var config: RelayConfig?
    public var readOnly: Bool
    public var version: String
    public var shortcutLabel: String?
    public var shortcutProblem: ShortcutProblem?
    public var presenceLine: String
    public var away: Bool
    public var login: LoginState
    public var displays: [DisplayOption]
    public var sourceKey: String
    public var connection: ConnectionLine
    public var connectionProblems: [String]
    public var permission: NotificationPermission
    public var repo: RepoState
    public var localQueuePath: String?
    public var now: Date

    public init(config: RelayConfig? = nil, readOnly: Bool = false, version: String = "",
                shortcutLabel: String? = nil, shortcutProblem: ShortcutProblem? = nil,
                presenceLine: String = "", away: Bool = false, login: LoginState = LoginState(),
                displays: [DisplayOption] = [], sourceKey: String = SourceKey.none,
                connection: ConnectionLine = ConnectionStatus.line(
                    sourceKey: SourceKey.none, reachable: false, loadedOnce: false, waiting: 0, problem: nil),
                connectionProblems: [String] = [], permission: NotificationPermission = .notDetermined,
                repo: RepoState = RepoState(), localQueuePath: String? = nil,
                now: Date = Date(timeIntervalSince1970: 0)) {
        self.config = config
        self.readOnly = readOnly
        self.version = version
        self.shortcutLabel = shortcutLabel
        self.shortcutProblem = shortcutProblem
        self.presenceLine = presenceLine
        self.away = away
        self.login = login
        self.displays = displays
        self.sourceKey = sourceKey
        self.connection = connection
        self.connectionProblems = connectionProblems
        self.permission = permission
        self.repo = repo
        self.localQueuePath = localQueuePath
        self.now = now
    }
}

/// What a Settings or Welcome control asks the app to do.
public enum SettingsAction: Equatable {
    case showConfigInFinder, showQueueInFinder, chooseTokenFile, chooseRepoFolder, installSkill, copyClaudeMdSection
    case redockNow, requestNotifications, openNotificationSettings, sendTestNotification, openLoginItems, setLogin(Bool)
    case beginShortcut, recordShortcut(HotkeySpec?), cancelShortcut, clearShortcut, showAsk(String), switchTab(SettingsTabID), showPanel
}
