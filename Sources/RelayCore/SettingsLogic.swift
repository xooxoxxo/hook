import Foundation

// MARK: Tabs

extension SettingsTabID {
    public static let defaultsKey = "relay.settings.tabID"
    /// 0.5.x saved the tab here, as an index (0–3) or a raw value.
    public static let legacyDefaultsKey = "relay.settings.tab"
    static let legacyOrder: [SettingsTabID] = [.general, .queue, .notifications, .agents]

    /// A saved tab id: its raw value, or "connect", the Agents tab's id before 0.13.
    public init?(stored raw: String) {
        if raw == "connect" {
            self = .agents
        } else if let tab = SettingsTabID(rawValue: raw) {
            self = tab
        } else {
            return nil
        }
    }

    /// The tab Settings opens on. A legacy value is migrated once: written as an id, then deleted.
    /// A saved "connect" is saved again as "agents".
    public static func restore(_ defaults: UserDefaults) -> SettingsTabID {
        if let raw = defaults.string(forKey: defaultsKey), let tab = SettingsTabID(stored: raw) {
            defaults.removeObject(forKey: legacyDefaultsKey)
            if tab.rawValue != raw { tab.save(defaults) }
            return tab
        }
        guard let legacy = defaults.object(forKey: legacyDefaultsKey) else { return .general }
        defaults.removeObject(forKey: legacyDefaultsKey)
        let tab: SettingsTabID
        if let raw = legacy as? String {
            tab = SettingsTabID(stored: raw) ?? .general
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
        case .agents: "Agents"
        }
    }

    public var symbol: String {
        switch self {
        case .general: "gearshape"
        case .panel: "sidebar.right"
        case .queue: "tray"
        case .notifications: "bell"
        case .agents: "terminal"
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

/// What Settings › Agents and the setup window's agents page show: the last
/// `relay integrations status`, and the command running now.
public struct AgentsState: Equatable, Sendable {
    public var repoPath: String?
    /// The MCP server's last authenticated call (This Mac only).
    public var lastCall: Date?
    /// nil until the first status has been read.
    public var status: IntegrationStatus?
    /// The command running now; a newer one waits for it.
    public var running: IntegrationCommand?
    /// The last failed command or status read, one line; nil after one that worked.
    public var error: String?
    /// A failed piece command's first line, by `AgentsState.key(harness:piece:)`.
    public var pieceErrors: [String: String]
    /// Reinstall All's result line (`IntegrationReport.reinstallLine`); nil until it ran.
    public var result: String?

    public init(repoPath: String? = nil, lastCall: Date? = nil, status: IntegrationStatus? = nil,
                running: IntegrationCommand? = nil, error: String? = nil, pieceErrors: [String: String] = [:],
                result: String? = nil) {
        self.repoPath = repoPath
        self.lastCall = lastCall
        self.status = status
        self.running = running
        self.error = error
        self.pieceErrors = pieceErrors
        self.result = result
    }

    public var busy: Bool { running != nil }

    /// The Fix… command for this piece is the one running.
    public func isRunning(harness: String, piece: String) -> Bool {
        running.flatMap(Self.key(for:)) == Self.key(harness: harness, piece: piece)
    }

    /// Set Up or Update for this harness is the one running.
    public func isRunning(harness: String) -> Bool {
        switch running {
        case .sync(_, _, let id?), .reinstall(let id?, nil, _): return id == harness
        default: return false
        }
    }

    public static func key(harness: String, piece: String) -> String { harness + "/" + piece }

    /// The piece row a command belongs to, when it names one (the Fix… menu's commands).
    public static func key(for command: IntegrationCommand) -> String? {
        switch command {
        case .accept(let harness, let piece?), .diff(let harness, let piece?),
             .reinstall(let harness?, let piece?, _):
            return key(harness: harness, piece: piece)
        default:
            return nil
        }
    }

    /// The setup window's agents page is done: the status is read and no detected harness is
    /// still "Not set up", apart from those the owner removed Hook from.
    public var allSetUp: Bool {
        guard let status else { return false }
        return !status.harnesses.contains { $0.detected && $0.state == .notSetUp && !$0.removed }
    }

    /// The harnesses on this Mac (detected, or set up by Hook): Claude Code first, then by name.
    public var onThisMac: [IntegrationStatus.Harness] {
        (status?.harnesses ?? []).filter { $0.detected || $0.managed }.sorted { a, b in
            if (a.id == "claude-code") != (b.id == "claude-code") { return a.id == "claude-code" }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    /// The table's other entries, by name: "N more supported".
    public var moreSupported: [IntegrationStatus.Harness] {
        (status?.harnesses ?? []).filter { !$0.detected && !$0.managed }.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    /// Settings › Agents opens on the first harness needing action, else the first one.
    public var defaultSelection: String? {
        let rows = onThisMac
        return (rows.first { $0.state.needsAction } ?? rows.first)?.id
    }

    /// The stored selection while it is still on this Mac, else `defaultSelection`.
    public func selection(stored: String?) -> String? {
        if let stored, onThisMac.contains(where: { $0.id == stored }) { return stored }
        return defaultSelection
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
    public var agents: AgentsState
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
    /// Settings › General › Privacy.
    public var privacy: PrivacyLine
    public var now: Date

    public init(config: RelayConfig? = nil, readOnly: Bool = false, version: String = "",
                shortcutLabel: String? = nil, shortcutProblem: ShortcutProblem? = nil,
                presenceLine: String = "", away: Bool = false, login: LoginState = LoginState(),
                displays: [DisplayOption] = [], sourceKey: String = SourceKey.none,
                connection: ConnectionLine = ConnectionStatus.line(
                    sourceKey: SourceKey.none, reachable: false, loadedOnce: false, waiting: 0, problem: nil),
                connectionProblems: [String] = [], permission: NotificationPermission = .notDetermined,
                agents: AgentsState = AgentsState(), localQueuePath: String? = nil,
                terminals: [TerminalChoice] = [], mailbox: MailboxVersionLine? = nil,
                documentAppName: String? = nil, install: InstallLine? = nil,
                privacy: PrivacyLine = PrivacyLine(),
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
        self.agents = agents
        self.localQueuePath = localQueuePath
        self.terminals = terminals
        self.mailbox = mailbox
        self.documentAppName = documentAppName
        self.install = install
        self.privacy = privacy
        self.now = now
    }
}

/// Settings › General › Privacy: the crash settings as they read, and the activity log's size.
public struct PrivacyLine: Equatable, Sendable {
    public var reports: CrashReportsSetting
    /// The saved target as it reads: a saved `pond` without My Pond on offer is GitHub.
    public var target: CrashTarget
    /// My Pond is offered: a Pond is the source and this Mac's owner key is approved.
    public var pondOffered: Bool
    public var logSize: Int

    public init(reports: CrashReportsSetting = .ask, target: CrashTarget = .github, pondOffered: Bool = false,
                logSize: Int = 0) {
        self.reports = reports
        self.target = target
        self.pondOffered = pondOffered
        self.logSize = logSize
    }

    public static func make(config: RelayConfig?, ownerKey: OwnerKeyState, logSize: Int) -> PrivacyLine {
        let isPond: Bool = {
            guard case .mailbox? = config?.resolvedSource() else { return false }
            return true
        }()
        let offered = isPond && ownerKey == .approved
        return PrivacyLine(reports: config?.crashReports ?? .ask,
                           target: (config?.crashReportTarget ?? .github).effective(pondOffered: offered),
                           pondOffered: offered, logSize: logSize)
    }

    /// "84 KB", "1.5 MB", or "Empty".
    public var sizeText: String { Self.sizeText(logSize) }

    public static func sizeText(_ bytes: Int) -> String {
        guard bytes > 0 else { return "Empty" }
        if bytes < 1024 * 1024 { return "\((bytes + 1023) / 1024) KB" }
        return String(format: "%.1f MB", Double(bytes) / (1024 * 1024))
    }
}

/// What a Settings or Welcome control asks the app to do.
public enum SettingsAction: Equatable {
    case showConfigInFinder, showQueueInFinder, chooseTokenFile, chooseRepoFolder
    case redockNow, requestNotifications, openNotificationSettings, sendTestNotification, openLoginItems, setLogin(Bool)
    case beginShortcut, recordShortcut(HotkeySpec?), cancelShortcut, clearShortcut, showAsk(String), switchTab(SettingsTabID), showPanel
    /// Copy a text; open the Support Hook link.
    case copyText(String), openDonation
    /// Settings › Agents and the setup window: read `relay integrations status` again; run a
    /// command (then read the status again); a harness row's own button.
    case refreshAgents, integration(IntegrationCommand), agentAction(HarnessAction)
    /// Settings › Queue: read the mailbox's version now; run Update Mailbox….
    case checkMailbox, updateMailbox
    /// Settings › General › Open documents in › Other App…: pick an app and save it.
    case chooseDocumentApp
    /// Settings › General › Updates: Check for Updates….
    case checkForUpdates
    /// Settings › General › Privacy › Activity log: reveal hook.log in Finder.
    case showLogInFinder
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
