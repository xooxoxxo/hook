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

/// Why the global shortcut isn't working; a red caption under the recorder.
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

/// What Settings → Connect and the setup window show, read from `repoPath` and the home folder.
public struct RepoState: Equatable, Sendable {
    public var repoPath: String?
    public var mcpCommand: String?
    public var claudeMdAvailable: Bool
    public var skill: ConnectInfo.SkillState?
    public var cliFound: Bool
    public var lastCall: Date?
    /// The last failed skill install, one sentence; nil after a successful one.
    public var skillError: String?
    /// ~/.claude.json lists the relay MCP server (user scope).
    public var mcpRegistered: Bool
    /// The setup window's Register is running in the login shell.
    public var mcpBusy: Bool
    /// The last failed Register, one sentence; nil after a successful one.
    public var mcpError: String?
    /// ~/.claude/settings.json has the replies hook.
    public var hookInstalled: Bool
    /// The last failed hook merge, one sentence.
    public var hookError: String?
    /// ~/.claude/CLAUDE.md holds the section's heading.
    public var claudeMdInstalled: Bool
    public init(repoPath: String? = nil, mcpCommand: String? = nil, claudeMdAvailable: Bool = false,
                skill: ConnectInfo.SkillState? = nil, cliFound: Bool = false, lastCall: Date? = nil,
                skillError: String? = nil, mcpRegistered: Bool = false, mcpBusy: Bool = false,
                mcpError: String? = nil, hookInstalled: Bool = false, hookError: String? = nil,
                claudeMdInstalled: Bool = false) {
        self.repoPath = repoPath
        self.mcpCommand = mcpCommand
        self.claudeMdAvailable = claudeMdAvailable
        self.skill = skill
        self.cliFound = cliFound
        self.lastCall = lastCall
        self.skillError = skillError
        self.mcpRegistered = mcpRegistered
        self.mcpBusy = mcpBusy
        self.mcpError = mcpError
        self.hookInstalled = hookInstalled
        self.hookError = hookError
        self.claudeMdInstalled = claudeMdInstalled
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
    /// The Terminal picker: Automatic, then the installed terminals.
    public var terminals: [TerminalChoice]
    /// Settings › Queue › Connection's Mailbox row; nil outside mailbox mode.
    public var mailbox: MailboxVersionLine?
    /// The display name of the app "Open documents in" names; nil when it names none or
    /// the app isn't installed.
    public var documentAppName: String?
    /// Settings › General › Updates: how Hook was installed, so what an update does.
    public var install: InstallLine?
    public var now: Date

    public init(config: RelayConfig? = nil, readOnly: Bool = false, version: String = "",
                shortcutLabel: String? = nil, shortcutProblem: ShortcutProblem? = nil,
                presenceLine: String = "", away: Bool = false, login: LoginState = LoginState(),
                displays: [DisplayOption] = [], sourceKey: String = SourceKey.none,
                connection: ConnectionLine = ConnectionStatus.line(
                    sourceKey: SourceKey.none, reachable: false, loadedOnce: false, waiting: 0, problem: nil),
                connectionProblems: [String] = [], permission: NotificationPermission = .notDetermined,
                repo: RepoState = RepoState(), localQueuePath: String? = nil,
                terminals: [TerminalChoice] = [], mailbox: MailboxVersionLine? = nil,
                documentAppName: String? = nil, install: InstallLine? = nil,
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
        self.terminals = terminals
        self.mailbox = mailbox
        self.documentAppName = documentAppName
        self.install = install
        self.now = now
    }
}

/// What a Settings or Welcome control asks the app to do.
public enum SettingsAction: Equatable {
    case showConfigInFinder, showQueueInFinder, chooseTokenFile, chooseRepoFolder, installSkill, copyClaudeMdSection
    case redockNow, requestNotifications, openNotificationSettings, sendTestNotification, openLoginItems, setLogin(Bool)
    case beginShortcut, recordShortcut(HotkeySpec?), cancelShortcut, clearShortcut, showAsk(String), switchTab(SettingsTabID), showPanel
    /// Setup window: register the MCP server in the login shell; merge the replies hook
    /// into ~/.claude/settings.json; copy a text; open the Support Hook link.
    /// `checkAgents` re-reads what the agents page shows.
    case checkAgents, registerMCP, installRepliesHook, copyText(String), openDonation
    /// Settings › Queue: read the mailbox's version now; run Update Mailbox….
    case checkMailbox, updateMailbox
    /// Settings › General › Open documents in › Other App…: pick an app and save it.
    case chooseDocumentApp
    /// Settings › General › Updates: Check for Updates….
    case checkForUpdates
}

extension ShortcutProblem {
    /// The recorder's result: nil spec = a key Hook can't use; a spec macOS refused = refused.
    public static func forRecording(_ spec: HotkeySpec?, registered: Bool) -> ShortcutProblem? {
        guard spec != nil else { return .unsupportedKey }
        return registered ? nil : .refused
    }
}

/// Settings → Panel → Display.
public enum DisplayChoice {
    /// "Main display" (removes `sidebarDisplay`), then each connected display by name. A pinned
    /// display that isn't connected stays listed, disabled, so the pin is visible and kept.
    public static func options(screens: [DockScreen], names: [String: String], pinned: String?) -> [DisplayOption] {
        var options = [DisplayOption(id: nil, title: "Main display", connected: true)]
        options += screens.map { DisplayOption(id: $0.id, title: names[$0.id] ?? "Display", connected: true) }
        if let pinned, !screens.contains(where: { $0.id == pinned }) {
            options.append(DisplayOption(id: pinned, title: "\(names[pinned] ?? "Pinned display") (not connected)",
                                         connected: false))
        }
        return options
    }
}

extension NotifySettings {
    /// The `notify` object as config.json holds it; Settings saves the whole object.
    public var configObject: [String: Any] {
        ["now": now, "today": today, "whenever": whenever, "sound": sound, "slideIn": slideIn]
    }
}

// MARK: Queue

/// Picker titles for Settings → Queue. A hand-edited value outside the choices is listed too.
public enum ChoiceLabel {
    public static let pollChoices = [5, 15, 30, 60, 300]
    public static let keepChoices = [3, 7, 14, 30, 90]

    public static func poll(_ seconds: Int) -> String {
        switch seconds {
        case 60: "1 minute"
        case 300: "5 minutes"
        case _ where pollChoices.contains(seconds): "\(seconds) seconds"
        default: "\(seconds) seconds (from config.json)"
        }
    }

    public static func keepDays(_ days: Int) -> String {
        keepChoices.contains(days) ? "\(days) days" : "\(days) days (from config.json)"
    }
}

/// `~` for the home folder, both ways; `~user` forms are left alone.
public enum TildePath {
    public static func expand(_ path: String, home: String) -> String {
        if path == "~" { return home }
        if path.hasPrefix("~/") { return home + path.dropFirst() }
        return path
    }

    public static func abbreviate(_ path: String, home: String) -> String {
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }
}

extension MailboxDraft {
    /// The longest Connect waits for the first list.
    public static let connectTimeout: TimeInterval = 10
    /// Connect's reason when the mailbox didn't answer in time.
    public static let noAnswer = "no answer within 10 seconds"

    /// The fields as the saved config fills them; the default context shows as empty.
    public init(config: RelayConfig?, home: String) {
        let context = config?.context ?? RelayConfig.defaultContext
        self.init(address: config?.mailboxURL ?? "",
                  tokenFile: TildePath.abbreviate(config?.tokenFile ?? "", home: home),
                  context: context == RelayConfig.defaultContext ? "" : context)
    }

    /// Differs from the saved config, ignoring surrounding spaces, `~` spelling and an
    /// empty context standing for the default.
    public func isDirty(against config: RelayConfig?, home: String) -> Bool {
        normalized(home: home) != MailboxDraft(config: config, home: home).normalized(home: home)
    }

    /// One caption per field, or nil.
    public func errors() -> (address: String?, tokenFile: String?) {
        let address = self.address.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = tokenFile.trimmingCharacters(in: .whitespacesAndNewlines)
        var addressError: String?
        if address.isEmpty {
            addressError = "Enter the Pond URL."
        } else if let url = URL(string: address), let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https", let host = url.host(), !host.isEmpty {
            addressError = nil
        } else {
            addressError = "The address must start with http:// or https://."
        }
        return (addressError, token.isEmpty ? "Enter the token file." : nil)
    }

    /// The merge-save for Connect: the mailbox source, the trimmed address, the expanded
    /// token path, and the context (an empty one removes the key).
    public func changes(home: String) -> (set: [String: Any], remove: [String]) {
        let fields = normalized(home: home)
        var set: [String: Any] = ["source": SourceKind.mailbox.rawValue, "mailboxURL": fields.address, "tokenFile": fields.tokenFile]
        guard !fields.context.isEmpty else { return (set, ["context"]) }
        set["context"] = fields.context
        return (set, [])
    }

    private func normalized(home: String) -> MailboxDraft {
        let context = self.context.trimmingCharacters(in: .whitespacesAndNewlines)
        return MailboxDraft(
            address: address.trimmingCharacters(in: .whitespacesAndNewlines),
            tokenFile: TildePath.expand(tokenFile.trimmingCharacters(in: .whitespacesAndNewlines), home: home),
            context: context == RelayConfig.defaultContext ? "" : context)
    }
}

extension TestAskResult {
    /// How long the result line stays.
    public static let hold: TimeInterval = 30
}

extension ConnectionStatus {
    /// Settings → Queue → Connection's red captions: the config and listener notes, each
    /// one revealed line (a config note can embed a JSON parser message).
    public static func problems(configNote: String?, listenerNote: String?) -> [String] {
        [configNote, listenerNote].compactMap { $0 }.map { UserFacingError.text($0) }
    }
}

extension NotificationPermission {
    /// How long "Sent." stays after Send a Test Notification.
    public static let sentFor: TimeInterval = 5

    /// The Permission row's text; nil when it is only a button.
    public var statusText: String? {
        switch self {
        case .authorized: "Allowed"
        case .denied: "Turned off in System Settings"
        case .notDetermined: nil
        }
    }

    public var action: SettingsAction? {
        switch self {
        case .authorized: nil
        case .denied: .openNotificationSettings
        case .notDetermined: .requestNotifications
        }
    }

    public var actionTitle: String? {
        switch self {
        case .authorized: nil
        case .denied: "Open System Settings"
        case .notDetermined: "Allow Notifications…"
        }
    }
}
