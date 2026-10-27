import Foundation
import RelayCore

/// An in-memory Settings model for the gallery; every action is a no-op.
public final class FixtureSettingsModel: SettingsViewModel {
    @Published public var settings: SettingsSnapshot
    @Published public var draft: MailboxDraft

    public init(settings: SettingsSnapshot, draft: MailboxDraft = MailboxDraft()) {
        self.settings = settings
        self.draft = draft
    }

    public func save(set: [String: Any], remove: [String]) {}
    public func perform(_ action: SettingsAction) {}
    public func sendTestAsk() async -> TestAskResult { .sent(id: SettingsFixtures.testAskID) }
    public func connect() async -> String? { nil }
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
    /// The mailbox config with Presence set to Away by hand, so "Away after" is hidden.
    public static let manualAwayConfig: RelayConfig = {
        var config = mailboxConfig
        config.presence = .away
        return config
    }()
    public static let repo = RepoState(
        repoPath: repoPath,
        mcpCommand: #"claude mcp add --scope user relay -- python3 "$HOME/src/relay/mcp/relay_mcp.py""#,
        claudeMdAvailable: true, skill: .installed, cliFound: true,
        lastCall: GalleryFixtures.now.addingTimeInterval(-120))

    /// The setup window's agents page, half done: MCP and the skill in, the hook and CLAUDE.md not.
    public static let setupRepo: RepoState = {
        var state = SettingsFixtures.repo
        state.mcpRegistered = true
        return state
    }()
    /// Everything connected.
    public static let setupRepoDone: RepoState = {
        var state = setupRepo
        state.hookInstalled = true
        state.claudeMdInstalled = true
        return state
    }()

    public static func snapshot(config: RelayConfig? = mailboxConfig, readOnly: Bool = false, away: Bool = false,
                                presenceLine: String? = nil,
                                permission: NotificationPermission = .authorized, repo: RepoState = repo,
                                shortcutLabel: String? = "⌃⌥⌘R",
                                shortcutProblem: ShortcutProblem? = nil, login: LoginState = LoginState(on: true),
                                problems: [String] = [],
                                displays: [DisplayOption] = [
                                    DisplayOption(id: nil, title: "Main display", connected: true),
                                    DisplayOption(id: "D1", title: "Studio Display", connected: true),
                                ]) -> SettingsSnapshot {
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
            connectionProblems: problems, permission: permission, repo: repo,
            localQueuePath: "~/Library/Application Support/Relay/queue.json",
            terminals: TerminalChoice.options(installed: [.terminal, .ghostty, .iterm],
                                              current: config?.terminal ?? RelayConfig.automaticTerminal),
            now: GalleryFixtures.now)
    }
}
