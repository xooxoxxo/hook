import Foundation

// What `relay integrations` (clients/relay_integrations.py) reports, and the commands the app
// runs through it. Settings › Agents and the setup window read these; the app's
// IntegrationsRunner runs the commands in the login shell.

/// `relay integrations status --json`. Unknown keys are ignored; an unknown state fails the
/// decode, so a newer CLI that adds one shows as an error instead of a wrong label.
public struct IntegrationStatus: Decodable, Equatable, Sendable {
    public var schema: Int
    public var hookVersion: String
    public var autoSetup: Bool
    public var lastSync: Date?
    public var harnesses: [Harness]
    /// Detected harnesses Hook hasn't set up.
    public var newlyDetected: [String]
    public var migrations: [Migration]
    public var errors: [String]

    public init(schema: Int = 1, hookVersion: String = "", autoSetup: Bool = true, lastSync: Date? = nil,
                harnesses: [Harness] = [], newlyDetected: [String] = [], migrations: [Migration] = [],
                errors: [String] = []) {
        self.schema = schema
        self.hookVersion = hookVersion
        self.autoSetup = autoSetup
        self.lastSync = lastSync
        self.harnesses = harnesses
        self.newlyDetected = newlyDetected
        self.migrations = migrations
        self.errors = errors
    }

    public struct Harness: Decodable, Equatable, Sendable, Identifiable {
        public var id: String
        public var name: String
        public var detected: Bool
        public var managed: Bool
        public var state: HarnessState
        /// `machine`, `pending` or `docs-only`.
        public var verified: String
        public var pieces: [Piece]
        public var ownerSteps: [OwnerStep]
        public var changes: [Change]
        /// The owner removed Hook from it: no scheduled sync sets it up again, and it is never
        /// offered as new. Set Up (`sync --harness X`) brings it back.
        public var removed: Bool

        public init(id: String, name: String, detected: Bool, managed: Bool, state: HarnessState, verified: String,
                    pieces: [Piece], ownerSteps: [OwnerStep], changes: [Change], removed: Bool = false) {
            self.id = id
            self.name = name
            self.detected = detected
            self.managed = managed
            self.state = state
            self.verified = verified
            self.pieces = pieces
            self.ownerSteps = ownerSteps
            self.changes = changes
            self.removed = removed
        }

        enum CodingKeys: String, CodingKey {
            case id, name, detected, managed, state, verified, pieces, ownerSteps, changes, removed
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            name = try c.decode(String.self, forKey: .name)
            detected = try c.decode(Bool.self, forKey: .detected)
            managed = try c.decode(Bool.self, forKey: .managed)
            state = try c.decode(HarnessState.self, forKey: .state)
            verified = try c.decodeIfPresent(String.self, forKey: .verified) ?? ""
            pieces = try c.decode([Piece].self, forKey: .pieces)
            ownerSteps = try c.decodeIfPresent([OwnerStep].self, forKey: .ownerSteps) ?? []
            changes = try c.decodeIfPresent([Change].self, forKey: .changes) ?? []
            removed = try c.decodeIfPresent(Bool.self, forKey: .removed) ?? false
        }
    }

    /// One of a harness's four pieces: mcp, skill, instructions, replies.
    public struct Piece: Decodable, Equatable, Sendable {
        public var piece: String
        /// `plugin`, `cli`, `file`, `copy`, `block`, `key`, `owner` or `none`.
        public var method: String
        public var state: PieceState
        /// What Hook writes, as a `~` path; nil for a piece with nothing on disk.
        public var target: String?
        /// The key path inside `target`, for a key or CLI piece.
        public var key: String?
        public var note: String?
        /// Show Difference can compare Hook's text with the file (block, key, file and copy pieces).
        public var diffable: Bool
        /// Keep Mine can keep the edit. False when Hook's piece moved to a file the agent reads
        /// instead (Codex's AGENTS.override.md), so the edit is in a file it no longer reads.
        public var keepable: Bool
        /// The path the folder button reveals, nil when nothing there exists yet.
        public var reveal: String?

        /// `keepable` nil: an edited piece can be kept.
        public init(piece: String, method: String, state: PieceState, target: String?, key: String?, note: String?,
                    diffable: Bool, keepable: Bool? = nil, reveal: String?) {
            self.piece = piece
            self.method = method
            self.state = state
            self.target = target
            self.key = key
            self.note = note
            self.diffable = diffable
            self.keepable = keepable ?? Self.edited(state)
            self.reveal = reveal
        }

        enum CodingKeys: String, CodingKey {
            case piece, method, state, target, key, note, diffable, keepable, reveal
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            piece = try c.decode(String.self, forKey: .piece)
            method = try c.decode(String.self, forKey: .method)
            state = try c.decode(PieceState.self, forKey: .state)
            target = try c.decodeIfPresent(String.self, forKey: .target)
            key = try c.decodeIfPresent(String.self, forKey: .key)
            note = try c.decodeIfPresent(String.self, forKey: .note)
            diffable = try c.decode(Bool.self, forKey: .diffable)
            keepable = try c.decodeIfPresent(Bool.self, forKey: .keepable) ?? Self.edited(state)
            reveal = try c.decodeIfPresent(String.self, forKey: .reveal)
        }

        static func edited(_ state: PieceState) -> Bool { state == .drifted || state == .foreign }
    }

    /// A step only the owner can do, posted as an ask.
    public struct OwnerStep: Decodable, Equatable, Sendable {
        public var id: String
        public var title: String
        /// nil until the ask is posted.
        public var askId: String?
        /// The ask's state: `pending` (not posted yet), `open`, `done` or `skipped`.
        public var state: String

        public init(id: String, title: String, askId: String?, state: String) {
            self.id = id
            self.title = title
            self.askId = askId
            self.state = state
        }

        public var isOpen: Bool { state == "open" || state == "pending" }
    }

    /// One path Hook changed for this harness, for the "?" list.
    public struct Change: Decodable, Equatable, Sendable {
        public var path: String
        public var what: String

        public init(path: String, what: String) {
            self.path = path
            self.what = what
        }
    }

    /// A step of the Claude Code migration (`claude-md` while its proposal waits on the owner).
    public struct Migration: Decodable, Equatable, Sendable {
        public var id: String
        public var state: String
        public var askId: String?
        public var path: String?

        public init(id: String, state: String, askId: String?, path: String? = nil) {
            self.id = id
            self.state = state
            self.askId = askId
            self.path = path
        }
    }

    /// The decoder for every `relay integrations` answer: ISO 8601 dates ("2026-11-04T09:30:00Z").
    public static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    public static func decode(_ data: Data) throws -> IntegrationStatus {
        try decoder.decode(IntegrationStatus.self, from: data)
    }
}

public enum HarnessState: String, Decodable, Sendable, CaseIterable {
    case notSetUp = "not-set-up", installed, outdated, drifted, needsOwner = "needs-owner", blocked
}

public enum PieceState: String, Decodable, Sendable, CaseIterable {
    case notSetUp = "not-set-up", installed, accepted, outdated, drifted, foreign,
         needsOwner = "needs-owner", blocked, none
}

extension HarnessState {
    public var label: String {
        switch self {
        case .notSetUp: return "Not set up"
        case .installed: return "Installed"
        case .outdated: return "Update ready"
        case .drifted: return "Edited by you"
        case .needsOwner, .blocked: return "Needs you"
        }
    }
}

extension HarnessState {
    /// Update ready, Edited by you and Needs you: the sidebar row gets a trailing symbol.
    public var needsAction: Bool {
        switch self {
        case .outdated, .drifted, .needsOwner, .blocked: return true
        case .notSetUp, .installed: return false
        }
    }
}

extension PieceState {
    /// `harness` names the harness for a piece it has no place for.
    public func label(harness name: String) -> String {
        switch self {
        case .notSetUp: return "Not set up"
        case .installed, .accepted: return "Installed"
        case .outdated: return "Update ready"
        case .drifted, .foreign: return "Edited by you"
        case .needsOwner, .blocked: return "Needs you"
        case .none: return "Not available in \(name)"
        }
    }

    /// The "?" note of a piece whose edit the owner kept (Keep Mine).
    public var keptNote: String? {
        self == .accepted ? "Your edit is kept. Hook asks again only if its own text changes." : nil
    }
}

/// What a harness row's own button does.
public enum HarnessAction: Equatable, Sendable {
    case setUp(String), update(String), openAsk(String), reveal(String)

    /// The command it runs; nil for the actions the app does itself (show an ask, reveal a path).
    public var command: IntegrationCommand? {
        switch self {
        case .setUp(let id), .update(let id): return .sync(ifChanged: false, includeNew: false, harness: id)
        case .openAsk, .reveal: return nil
        }
    }
}

/// The Fix… menu on a piece marked "Edited by you" (owner pick 6).
public enum PieceFix: Equatable, Sendable {
    case keepMine, showDifference, useHooks
}

extension IntegrationStatus.Harness {
    /// not-set-up → Set Up, outdated → Update, needs-owner → the first open ask, blocked →
    /// reveal the first blocked piece. Drifted has none: each edited piece has its own Fix… menu.
    public var action: HarnessAction? {
        switch state {
        case .notSetUp: return .setUp(id)
        case .outdated: return .update(id)
        case .needsOwner:
            return ownerSteps.first { $0.isOpen && $0.askId != nil }?.askId.map(HarnessAction.openAsk)
        case .blocked:
            guard let piece = pieces.first(where: { $0.state == .blocked }),
                  let path = piece.reveal ?? piece.target else { return nil }
            return .reveal(path)
        case .installed, .drifted: return nil
        }
    }
}

extension IntegrationStatus.Piece {
    public var fixes: [PieceFix] {
        guard Self.edited(state) else { return [] }
        return (keepable ? [.keepMine] : []) + (diffable ? [.showDifference] : []) + [.useHooks]
    }

    public func label(harness name: String) -> String { state.label(harness: name) }
}

/// One `relay integrations` run.
public enum IntegrationCommand: Equatable, Sendable {
    case status
    case sync(ifChanged: Bool, includeNew: Bool, harness: String?)
    case reinstall(harness: String?, piece: String?, force: Bool)
    case accept(harness: String, piece: String?)
    case diff(harness: String, piece: String?)
    /// nil removes everything (`--all`).
    case remove(harness: String?)
    case setAutoSetup(Bool)
    /// The owner's answer to the CLAUDE.md proposal: Apply, Remove the whole section, Keep CLAUDE.md as is.
    case migrate(choice: String)

    /// The words after `relay integrations`; always ends with `--json`.
    public var arguments: [String] {
        func scope(_ harness: String?, _ piece: String? = nil) -> [String] {
            (harness.map { ["--harness", $0] } ?? []) + (piece.map { ["--piece", $0] } ?? [])
        }
        let words: [String]
        switch self {
        case .status:
            words = ["status"]
        case let .sync(ifChanged, includeNew, harness):
            words = ["sync"] + scope(harness) + (ifChanged ? ["--if-changed"] : []) + (includeNew ? ["--include-new"] : [])
        case let .reinstall(harness, piece, force):
            words = ["reinstall"] + scope(harness, piece) + (force ? ["--force"] : [])
        case let .accept(harness, piece):
            words = ["accept"] + scope(harness, piece)
        case let .diff(harness, piece):
            words = ["diff"] + scope(harness, piece)
        case .remove(let harness):
            words = ["remove"] + (harness.map { ["--harness", $0] } ?? ["--all"])
        case .setAutoSetup(let on):
            words = ["set", "auto-setup", on ? "on" : "off"]
        case .migrate(let choice):
            words = ["migrate", "claude-md", "--choose", choice]
        }
        return words + ["--json"]
    }

    /// Keep Mine is `accept`, Show Difference is `diff`, Use Hook's is `reinstall --force`.
    public static func fix(_ fix: PieceFix, harness: String, piece: String) -> IntegrationCommand {
        switch fix {
        case .keepMine: return .accept(harness: harness, piece: piece)
        case .showDifference: return .diff(harness: harness, piece: piece)
        case .useHooks: return .reinstall(harness: harness, piece: piece, force: true)
        }
    }

    /// 15 s for the reads, 120 s for anything that writes (a harness CLI or an ask may be slow).
    public var timeout: TimeInterval {
        switch self {
        case .status, .diff: return 15
        default: return 120
        }
    }

    /// `<repo>/bin/relay`, or nil when the repo path is unset or not absolute.
    public static func relayPath(repoPath: String?) -> String? {
        guard let repoPath else { return nil }
        let folder = ConnectInfo.normalized(repoPath)
        guard folder.hasPrefix("/") else { return nil }
        return (folder == "/" ? "" : folder) + "/bin/relay"
    }

    /// What the login shell runs: every word single-quoted, stdout and stderr into the two
    /// files, so what a login profile prints never mixes with the JSON.
    public func shellLine(repoPath: String, stdout: String, stderr: String) -> String {
        let relay = Self.relayPath(repoPath: repoPath) ?? ConnectInfo.normalized(repoPath) + "/bin/relay"
        return Shell.quote(relay) + " integrations " + arguments.map(Shell.quote).joined(separator: " ")
            + " >" + Shell.quote(stdout) + " 2>" + Shell.quote(stderr)
    }
}

/// Why a `relay integrations` run gave nothing to read.
public enum IntegrationError: Error, Equatable, Sendable {
    /// No repo path, or no bin/relay in it.
    case notInstalled
    case timedOut
    /// It succeeded but printed nothing.
    case noOutput
    /// It printed something that isn't the expected JSON.
    case unreadable
    /// It exited with an error: the first line it gave.
    case failed(String)

    /// One line for a Settings row.
    public var text: String {
        switch self {
        case .notInstalled: return "Hook's relay command isn't in the Hook repo folder"
        case .timedOut: return "relay integrations didn't finish in time"
        case .noOutput: return "relay integrations gave no answer"
        case .unreadable: return "relay integrations gave an answer Hook can't read"
        case .failed(let line): return Sanitize.revealLine(line)
        }
    }
}

public enum IntegrationOutcome {
    /// Exit 0, or 4 (an item failed; the JSON says which), keeps stdout. Any other exit
    /// gives its first stderr line without the "relay integrations: " prefix (argparse's
    /// usage line is skipped), else the login shell's last line, else the status.
    public static func interpret(status: Int32, timedOut: Bool, stdout: Data, stderr: String,
                                 shellOutput: String) -> Result<Data, IntegrationError> {
        if timedOut { return .failure(.timedOut) }
        if status == 0 || status == 4 {
            let blank = String(decoding: stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            return blank ? .failure(.noOutput) : .success(stdout)
        }
        let prefix = "relay integrations: "
        let lines = stderr.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if let line = lines.first(where: { $0.hasPrefix(prefix) }) ?? lines.first(where: { !$0.hasPrefix("usage:") }) {
            return .failure(.failed(line.hasPrefix(prefix) ? String(line.dropFirst(prefix.count)) : line))
        }
        if let last = shellOutput.split(separator: "\n").last.map(String.init), !last.isEmpty {
            return .failure(.failed(last))
        }
        return .failure(.failed("It stopped with status \(status)"))
    }
}

/// `sync`, `reinstall`, `remove` and `migrate --json`.
public struct IntegrationReport: Decodable, Equatable, Sendable {
    public var dryRun: Bool
    public var results: [Result]
    public var errors: [String]
    public var exit: Int

    public struct Result: Decodable, Equatable, Sendable {
        public var harness: String
        public var piece: String
        public var action: String
        public var target: String?
        public var outcome: String
        public var note: String?
    }

    public static func decode(_ data: Data) throws -> IntegrationReport {
        try IntegrationStatus.decoder.decode(IntegrationReport.self, from: data)
    }

    /// Reinstall All's line: edits Hook left alone (`skipped`) and pieces it couldn't write.
    public var reinstallLine: String {
        let kept = results.filter { $0.outcome == "skipped" }.count
        let failed = results.filter { $0.outcome == "failed" || $0.outcome == "blocked" }.count
        var line = "Reinstalled."
        switch kept {
        case 0: break
        case 1: line += " 1 change you made stays as you left it."
        default: line += " \(kept) changes you made stay as you left them."
        }
        if failed > 0 { line += " \(failed) couldn't be written." }
        return line
    }
}

/// `diff --harness X --piece P --json`: Hook's text against the file, as a unified diff.
public struct IntegrationDiff: Decodable, Equatable, Sendable {
    public var harness: String
    public var piece: String
    public var target: String
    public var diff: String

    public init(harness: String, piece: String, target: String, diff: String) {
        self.harness = harness
        self.piece = piece
        self.target = target
        self.diff = diff
    }

    public static func decode(_ data: Data) throws -> IntegrationDiff {
        try IntegrationStatus.decoder.decode(IntegrationDiff.self, from: data)
    }
}

/// When the app runs `sync`: once `launchDelay` after launch (`--if-changed`), then whenever
/// a day has passed since the last sync.
public enum IntegrationSchedule {
    public static let launchDelay: TimeInterval = 30
    public static let interval: TimeInterval = 24 * 60 * 60
    /// How often the app checks `dailyDue` between wakes.
    public static let checkEvery: TimeInterval = 60 * 60
    /// A last sync further ahead than this means the clock stepped back.
    static let futureSlack: TimeInterval = 60

    public static func dailyDue(lastSync: Date?, now: Date) -> Bool {
        guard let lastSync else { return true }
        let elapsed = now.timeIntervalSince(lastSync)
        return elapsed >= interval || elapsed < -futureSlack
    }
}

/// The info Notice for harnesses found while "Set up new agents automatically" is off.
/// Each id is offered until the owner dismisses its Notice; dismissed ids stay in UserDefaults.
public enum IntegrationNotice {
    public static let defaultsKey = "integrations.dismissedNewAgents"

    public static func ids(newlyDetected: [String], dismissed: Set<String>, autoSetup: Bool) -> [String] {
        autoSetup ? [] : newlyDetected.filter { !dismissed.contains($0) }
    }

    public static func ids(status: IntegrationStatus, dismissed: Set<String>) -> [String] {
        ids(newlyDetected: status.newlyDetected, dismissed: dismissed, autoSetup: status.autoSetup)
    }

    /// Each id's harness name; an id the status doesn't list stays as it is.
    public static func names(ids: [String], status: IntegrationStatus) -> [String] {
        ids.map { id in status.harnesses.first { $0.id == id }?.name ?? id }
    }

    public static func text(names: [String]) -> String {
        let list: String
        switch names.count {
        case 0, 1: list = names.first ?? "a new agent"
        default: list = names.dropLast().joined(separator: ", ") + " and " + (names.last ?? "")
        }
        return "Hook found \(list). Set \(names.count > 1 ? "them" : "it") up in Settings › Agents."
    }

    public static func dismissed(in defaults: UserDefaults) -> Set<String> {
        Set((defaults.array(forKey: defaultsKey) as? [String]) ?? [])
    }

    /// Adds `ids`, keeping the order they were first dismissed in.
    public static func dismiss(_ ids: [String], in defaults: UserDefaults) {
        var list = (defaults.array(forKey: defaultsKey) as? [String]) ?? []
        for id in ids where !list.contains(id) { list.append(id) }
        defaults.set(list, forKey: defaultsKey)
    }
}

/// Runs one job at a time, in the order asked: a newer job waits for the one before it.
@MainActor public final class SerialTasks {
    private var tail: Task<Void, Never>?

    public init() {}

    public func run<T: Sendable>(_ body: @escaping @MainActor @Sendable () async -> T) async -> T {
        let previous = tail
        let task = Task { @MainActor () -> T in
            await previous?.value
            return await body()
        }
        tail = Task { @MainActor in _ = await task.value }
        return await task.value
    }
}
