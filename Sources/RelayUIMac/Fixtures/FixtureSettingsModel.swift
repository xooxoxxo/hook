import RelayMacCore
import RelayUI
import Foundation
import RelayCore

/// An in-memory Settings model for the gallery; every action is a no-op.
public final class FixtureSettingsModel: SettingsViewModel {
    public let phonePairing = PhonePairingController()
    public var revokePendingID: String? { nil }
    public var revokeProblem: String? { nil }
    public func revokeOwnerKey(_ id: String) {}
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
    public func integrationDiff(harness: String, piece: String) async -> Result<IntegrationDiff, IntegrationError> {
        .success(SettingsFixtures.agentsDiff)
    }
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

    /// Settings › Agents on a Mac with nine agents: every state the pane draws, and nine more
    /// supported that aren't here. Paths are `~` paths; nothing names a real home or host.
    public static let codexAskID = "7c1d2e3f-0000-4000-8000-000000000001"
    public static let agentsMacStatus: IntegrationStatus = {
        typealias Piece = IntegrationStatus.Piece
        func installed(_ piece: String, _ method: String, _ target: String?, key: String? = nil,
                       state: PieceState = .installed, note: String? = nil, diffable: Bool = false) -> Piece {
            Piece(piece: piece, method: method, state: state, target: target, key: key, note: note, diffable: diffable,
                  reveal: target)
        }
        func entry(_ id: String, _ name: String, _ state: HarnessState, detected: Bool = true, managed: Bool = true,
                   verified: String = "pending", pieces: [Piece], steps: [IntegrationStatus.OwnerStep] = [],
                   changes: [IntegrationStatus.Change] = []) -> IntegrationStatus.Harness {
            IntegrationStatus.Harness(id: id, name: name, detected: detected, managed: managed, state: state,
                                      verified: verified, pieces: pieces, ownerSteps: steps, changes: changes)
        }
        func absent(_ id: String, _ name: String) -> IntegrationStatus.Harness {
            entry(id, name, .notSetUp, detected: false, managed: false, verified: "docs-only",
                  pieces: ["mcp", "skill", "instructions", "replies"].map {
                      Piece(piece: $0, method: "key", state: .notSetUp, target: nil, key: nil, note: nil,
                            diffable: false, reveal: nil)
                  })
        }
        let skill = installed("skill", "copy", "~/.agents/skills/instructables")
        let claudePlugin = "~/.local/share/hook/plugins/claude-code"
        let harnesses = [
            entry("claude-code", "Claude Code", .installed, pieces: [
                installed("mcp", "cli", "~/.claude.json", key: "mcpServers.relay"),
                installed("skill", "plugin", claudePlugin),
                installed("instructions", "file", "~/.claude/rules/hook.md", state: .accepted, note: "your edit is kept"),
                installed("replies", "plugin", claudePlugin),
            ], changes: [IntegrationStatus.Change(path: "~/.claude.json", what: "command mcp"),
                         IntegrationStatus.Change(path: "~/.claude/rules/hook.md", what: "file"),
                         IntegrationStatus.Change(path: claudePlugin, what: "plugin")]),
            entry("codex", "Codex", .needsOwner, pieces: [
                installed("mcp", "cli", "~/.codex/config.toml", key: "mcp_servers.relay"),
                skill,
                installed("instructions", "block", "~/.codex/AGENTS.md"),
                installed("replies", "key", "~/.codex/hooks.json", key: "hooks.UserPromptSubmit", state: .needsOwner,
                          note: "only you can do this step"),
            ], steps: [IntegrationStatus.OwnerStep(id: "codex-trust", title: "Trust Hook's replies hook in Codex",
                                                   askId: codexAskID, state: "open")],
            changes: [IntegrationStatus.Change(path: "~/.codex/AGENTS.md", what: "block instructions"),
                      IntegrationStatus.Change(path: "~/.codex/hooks.json", what: "key hooks.UserPromptSubmit")]),
            entry("gemini-cli", "Gemini CLI", .outdated, pieces: [
                installed("mcp", "plugin", "~/.local/share/hook/plugins/gemini-cli", state: .outdated),
                installed("skill", "plugin", "~/.local/share/hook/plugins/gemini-cli", state: .outdated),
                installed("instructions", "plugin", "~/.local/share/hook/plugins/gemini-cli"),
                installed("replies", "plugin", "~/.local/share/hook/plugins/gemini-cli"),
            ]),
            entry("copilot-cli", "Copilot CLI", .installed, pieces: [
                installed("mcp", "key", "~/.copilot/mcp-config.json", key: "mcpServers.relay"),
                skill,
                installed("instructions", "file", "~/.copilot/instructions/hook.instructions.md"),
                installed("replies", "key", "~/.copilot/hooks/hook.json", key: "hooks.sessionStart"),
            ]),
            entry("vscode-copilot", "VS Code Copilot", .installed, verified: "docs-only", pieces: [
                installed("mcp", "key", "~/Library/Application Support/Code/User/mcp.json", key: "servers.relay"),
                skill,
                installed("instructions", "file", "~/.copilot/instructions/hook.instructions.md"),
                installed("replies", "key", "~/.copilot/hooks/hook.json", key: "hooks.sessionStart"),
            ]),
            entry("cursor", "Cursor", .notSetUp, managed: false, pieces: ["mcp", "skill", "instructions", "replies"].map {
                Piece(piece: $0, method: "plugin", state: .notSetUp, target: "~/.cursor/plugins/local/hook", key: nil,
                      note: nil, diffable: false, reveal: "~/.cursor")
            }),
            entry("opencode", "OpenCode", .drifted, pieces: [
                installed("mcp", "key", "~/.config/opencode/opencode.json", key: "mcp.relay", state: .drifted,
                          note: "edited by you", diffable: true),
                skill,
                installed("instructions", "key", "~/.config/opencode/opencode.json", key: "instructions"),
                installed("replies", "cli", "~/.config/opencode/plugins/hook.ts", state: .drifted, note: "edited by you"),
            ]),
            entry("zed", "Zed", .installed, pieces: [
                installed("mcp", "key", "~/.config/zed/settings.json", key: "context_servers.relay"),
                skill,
                installed("instructions", "block", "~/.config/zed/AGENTS.md"),
                Piece(piece: "replies", method: "none", state: .none, target: nil, key: nil,
                      note: "Zed documents no prompt or session hooks; the instructions cover it", diffable: false,
                      reveal: nil),
            ]),
            entry("pi", "pi", .installed, pieces: [
                installed("mcp", "key", "~/.pi/agent/mcp.json", key: "mcpServers.relay"),
                skill,
                installed("instructions", "block", "~/.pi/agent/AGENTS.md"),
                installed("replies", "file", "~/.pi/agent/extensions/hook.ts"),
            ]),
        ] + [("antigravity", "Antigravity CLI"), ("devin", "Devin"), ("factory", "Factory Droid"), ("kiro", "Kiro"),
             ("amp", "Amp"), ("cline", "Cline"), ("goose", "Goose"), ("junie", "Junie"), ("warp", "Warp")]
            .map { absent($0.0, $0.1) }
        return IntegrationStatus(hookVersion: "0.13.0", autoSetup: true,
                                 lastSync: GalleryFixtures.now.addingTimeInterval(-3600), harnesses: harnesses)
    }()

    public static let agentsMac = AgentsState(
        repoPath: repoPath, lastCall: GalleryFixtures.now.addingTimeInterval(-120), status: agentsMacStatus)

    /// Show Difference on OpenCode's MCP server, labelled as `relay integrations diff` labels it:
    /// the owner's edit first (it pinned /usr/bin/python3 and added a timeout), Hook's piece second.
    public static let agentsDiff = IntegrationDiff(
        harness: "opencode", piece: "mcp", target: "~/.config/opencode/opencode.json",
        diff: """
        --- ~/.config/opencode/opencode.json (yours)
        +++ ~/.config/opencode/opencode.json (Hook's)
        @@ -1,7 +1,6 @@
         "relay": {
           "type": "local",
        -  "command": ["/usr/bin/python3", "~/.local/share/hook/current/mcp/relay_mcp.py"],
        -  "timeout": 20000,
        +  "command": ["python3", "~/.local/share/hook/current/mcp/relay_mcp.py"],
           "enabled": true
         }
        """)

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
