import Foundation
import RelayCore

/// An in-memory Settings model for the gallery; every action is a no-op.
public final class FixtureSettingsModel: SettingsViewModel {
    @Published public var settings: SettingsSnapshot
    @Published public var draft: MailboxDraft
    @Published public var ownerKeyState: OwnerKeyState
    @Published public var ownerStatus: OwnerStatus?
    @Published public var canRequireOwnerKey: Bool
    @Published public var requireOffPending = false
    @Published public var requireProblem: String?

    public init(settings: SettingsSnapshot, draft: MailboxDraft = MailboxDraft(), ownerKeyState: OwnerKeyState = .notSetUp,
                ownerStatus: OwnerStatus? = nil, canRequireOwnerKey: Bool = false) {
        self.settings = settings
        self.draft = draft
        self.ownerKeyState = ownerKeyState
        self.ownerStatus = ownerStatus
        self.canRequireOwnerKey = canRequireOwnerKey
    }

    public func save(set: [String: Any], remove: [String]) {}
    public func perform(_ action: SettingsAction) {}
    public func sendTestAsk() async -> TestAskResult { .sent(id: SettingsFixtures.testAskID) }
    public func connect() async -> String? { nil }
    public func setUpOwnerKey() {}
    public func cancelOwnerKeySetup() {}
    public func requireOwnerKey(_ on: Bool) {}
    public func refreshOwnerStatus() {}
}

/// Generic Settings states for the gallery. Paths start at `~` (a generic `~/src/relay`
/// checkout) and the repo command uses `$HOME`, so no real home folder or layout reaches a PNG.
public enum SettingsFixtures {
    public static let testAskID = "1b2c3d4e-0000-4000-8000-000000000002"
    public static let repoPath = "~/src/relay"
    public static let mailboxConfig = RelayConfig(
        source: .mailbox, mailboxURL: "https://mailbox.example:8790",
        tokenFile: "~/.config/relay/mailbox-token", repoPath: repoPath)
    public static let localConfig = RelayConfig(source: .local, repoPath: repoPath)
    /// The mailbox config with an update command, for the Mailbox row's "Needs an update".
    public static let mailboxUpdateConfig = RelayConfig(
        source: .mailbox, mailboxURL: "https://mailbox.example:8790",
        tokenFile: "~/.config/relay/mailbox-token", repoPath: repoPath,
        mailboxUpdateCommand: "~/bin/update-mailbox")
    /// Settings › Queue's Pond row: in range, and below it.
    public static let mailboxOK = MailboxVersionLine(text: "Pond 1.1.0 ✓ (needs ^1.1.0)", state: .ok)
    public static let mailboxBehind = MailboxVersionLine(text: "Pond 1.0.0 (needs ^1.1.0)", state: .needsUpdate)
    /// The mailbox config with Presence set to Away by hand, so "Away after" is hidden.
    public static let manualAwayConfig: RelayConfig = {
        var config = mailboxConfig
        config.presence = .away
        return config
    }()
    /// Three agents on this Mac: Claude Code and Codex set up, Cursor found and not.
    public static let agentsStatus = IntegrationStatus(
        hookVersion: "0.13.0", autoSetup: true, lastSync: GalleryFixtures.now.addingTimeInterval(-3600),
        harnesses: [
            agentsHarness("claude-code", "Claude Code", state: .installed),
            agentsHarness("codex", "Codex", state: .installed),
            agentsHarness("cursor", "Cursor", state: .notSetUp, managed: false),
            agentsHarness("zed", "Zed", state: .notSetUp, detected: false, managed: false),
        ],
        newlyDetected: ["cursor"])

    public static let agents = AgentsState(
        repoPath: repoPath, lastCall: GalleryFixtures.now.addingTimeInterval(-120), status: agentsStatus)

    /// The setup window's agents page, done: every agent found is set up.
    public static let agentsDone: AgentsState = {
        var state = agents
        state.status?.harnesses = agentsStatus.harnesses.map { harness in
            var copy = harness
            if copy.detected { copy.state = .installed; copy.managed = true }
            return copy
        }
        state.status?.newlyDetected = []
        return state
    }()

    static func agentsHarness(_ id: String, _ name: String, state: HarnessState, detected: Bool = true,
                              managed: Bool = true) -> IntegrationStatus.Harness {
        let pieceState: PieceState = state == .installed ? .installed : .notSetUp
        return IntegrationStatus.Harness(
            id: id, name: name, detected: detected, managed: managed, state: state, verified: "pending",
            pieces: ["mcp", "skill", "instructions", "replies"].map {
                IntegrationStatus.Piece(piece: $0, method: "file", state: pieceState, target: nil, key: nil, note: nil,
                                        diffable: false, reveal: nil)
            },
            ownerSteps: [], changes: [])
    }

    public static func snapshot(config: RelayConfig? = mailboxConfig, readOnly: Bool = false, away: Bool = false,
                                presenceLine: String? = nil,
                                permission: NotificationPermission = .authorized, agents: AgentsState = agents,
                                shortcutLabel: String? = "⌃⌥⌘R",
                                shortcutProblem: ShortcutProblem? = nil, login: LoginState = LoginState(on: true),
                                problems: [String] = [],
                                mailbox: MailboxVersionLine? = mailboxOK,
                                displays: [DisplayOption] = [
                                    DisplayOption(id: nil, title: "Main display", connected: true),
                                    DisplayOption(id: "D1", title: "Studio Display", connected: true),
                                ],
                                ownerKey: OwnerKeyState = .approved, logSize: Int = 86_016) -> SettingsSnapshot {
        let sourceKey: String
        switch config?.resolvedSource() {
        case .mailbox(let settings)?: sourceKey = SourceKey.mailbox(settings)
        case .local?: sourceKey = SourceKey.local
        default: sourceKey = SourceKey.none
        }
        return SettingsSnapshot(
            config: config, readOnly: readOnly, version: "0.6.0",
            shortcutLabel: shortcutLabel, shortcutProblem: shortcutProblem,
            presenceLine: presenceLine ?? (away ? "Away · screen locked · since 10:22" : "Home · active"), away: away,
            login: login, displays: displays, sourceKey: sourceKey,
            connection: ConnectionStatus.line(sourceKey: sourceKey, reachable: true, loadedOnce: true, waiting: 5, problem: nil),
            connectionProblems: problems, permission: permission, agents: agents,
            localQueuePath: "~/Library/Application Support/Relay/queue.json",
            terminals: TerminalChoice.options(installed: [.terminal, .ghostty, .iterm],
                                              current: config?.terminal ?? RelayConfig.automaticTerminal),
            mailbox: sourceKey.hasPrefix("mailbox:") ? mailbox : nil,
            install: InstallKind.release(home: "/Users/me/.local/share/hook").line(home: "/Users/me"),
            privacy: PrivacyLine.make(config: config, ownerKey: ownerKey, logSize: logSize),
            now: GalleryFixtures.now)
    }
}
