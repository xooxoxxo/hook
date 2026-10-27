import Foundation
import os
import RelayCore
import RelayUI

/// What the loopback listener's `@Sendable` callbacks read. AppDelegate updates
/// it on every config apply; the lock makes reads safe from any thread.
final class ServerRouting: Sendable {
    struct Routes: Sendable {
        var source: String
        var api: LocalAPI?
        var token: LocalToken?
    }

    private let routes = OSAllocatedUnfairLock(initialState: Routes(source: "none", api: nil, token: nil))

    func update(_ next: Routes) {
        routes.withLock { $0 = next }
    }

    var api: LocalAPI? {
        routes.withLock { $0.api }
    }

    /// `GET /health`. The token is read (or recreated) per call and
    /// only used for the proof; it is never logged. `port` is the port of the
    /// listener that received the request (each `LoopbackServer` captures its own),
    /// so the proof is bound to it.
    func health(port: Int, nonce: String?) -> HTTPResponse {
        let current = routes.withLock { $0 }
        let token = current.source == "local" ? current.token.flatMap { try? $0.ensure() } : nil
        return Health.response(source: current.source, port: port, nonce: nonce, token: token)
    }
}

/// The config lifecycle (load, live reload, merge-save) and the state the
/// Settings and Welcome windows show. AppDelegate applies what it publishes.
@MainActor final class AppModel: ObservableObject {
    /// How often the loopback API's last-seen time is read for Settings → Connect.
    static let lastSeenPoll: Duration = .seconds(5)
    /// How often Connect (Queue tab and Welcome) checks whether the new mailbox has answered.
    static let connectPoll: Duration = .milliseconds(250)

    /// The last good config.
    @Published private(set) var config: RelayConfig?
    /// "config.json has an error: …", "config.json is missing", or a save failure.
    @Published private(set) var configNote: String?
    @Published private(set) var listenerState: ListenerState = .starting
    /// "mcp"/"cli" → last authenticated request; polled while the Connect tab is shown.
    @Published private(set) var lastSeen: [String: Date] = [:]
    /// Why the shortcut isn't working.
    @Published var shortcutProblem: ShortcutProblem?
    /// What the Settings and Welcome views read; only `refreshSettings()` writes it.
    @Published var settings = SettingsSnapshot()
    /// The Mailbox fields being edited; memory only.
    @Published var draft = MailboxDraft()
    /// Set by AppDelegate: what only the app shell can do.
    var hooks = SettingsHooks()
    weak var hotKeys: HotKeyManager?
    weak var notifier: Notifier?
    /// Set by AppDelegate on every presence change.
    var presenceLine = "Home · active"
    var away = false
    var permission: NotificationPermission = .notDetermined
    /// Re-reads `permission` whenever Hook becomes active; set once by `watchPermission()`.
    var permissionObserver: (any NSObjectProtocol)?
    var loginError: String?
    var skillError: String?
    /// The installed terminals for the Terminal picker, and when they were last looked up.
    var installedTerminals: Set<TerminalKind> = []
    var terminalsCheckedAt: Date?
    /// Names of displays seen in this run, for "<name> (not connected)".
    var displayNames: [String: String] = [:]

    /// `$HOME`, so a manual check can point it at a temp folder.
    nonisolated static var home: URL {
        ProcessInfo.processInfo.environment["HOME"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser
    }
    /// The registered global shortcut, e.g. "⌃⌥⌘R"; nil when off or not registered.
    @Published private(set) var shortcutLabel: String?

    /// A listener failure ("Port … is in use by another app") outside local mode,
    /// where it doesn't dim the menu bar or reach the Store's status line but
    /// still breaks "Open in Hook" links. Local mode shows it through
    /// the Store instead.
    var listenerNote: String? {
        guard case .failed(let text) = listenerState else { return nil }
        if case .local = resolvedSource { return nil }
        return text
    }

    let configURL: URL
    let dataDirectory: URL

    /// (old, new) after the config changed. Not called by `start()`.
    var onApply: (@MainActor (RelayConfig?, RelayConfig?) -> Void)?
    /// After `configNote` changed.
    var onNoteChange: (@MainActor (String?) -> Void)?
    /// Set by AppDelegate; `sendTestAsk` posts through it.
    weak var store: Store?
    /// Set by AppDelegate while the local source is up.
    var localAPI: LocalAPI?

    private var watcher: ConfigWatcher?
    private var lastSeenTask: Task<Void, Never>?

    var resolvedSource: ResolvedSource {
        config?.resolvedSource() ?? .incomplete
    }

    init(configURL: URL, dataDirectory: URL) {
        self.configURL = configURL
        self.dataDirectory = dataDirectory
    }

    /// `$RELAY_DATA_DIR` (tests and the smoke run only), else
    /// `~/Library/Application Support/Relay`.
    nonisolated static func dataDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let custom = environment["RELAY_DATA_DIR"], !custom.isEmpty {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/Relay", directoryHint: .isDirectory)
    }

    /// Launch: creates (or tightens) the private directories Hook owns, creates
    /// a custom config's folder only when missing, loads the config without
    /// calling `onApply`, and starts watching. Returns what it found.
    func start() -> ConfigLoad {
        let directories = RelayConfig.ownedDirectories(configURL: configURL, dataDirectory: dataDirectory)
        for directory in directories.tighten + directories.createOnly {
            do {
                if directories.tighten.contains(directory) {
                    try PrivateFile.ensureDirectory(directory)
                } else {
                    try PrivateFile.createDirectoryIfMissing(directory)
                }
            } catch {
                NSLog("Hook: can't create %@", directory.path)
            }
        }
        let load = Self.checked(ConfigStore.load(configURL))
        let next = ConfigReload.next(lastGood: nil, load: load)
        config = next.config
        setNote(load == .missing ? nil : next.note)

        let watcher = ConfigWatcher(url: configURL) { [weak self] load in
            self?.reload(load)
        }
        watcher.start()
        self.watcher = watcher
        return load
    }

    /// A reload from the watcher or after a save: keeps the last good config on
    /// an error, and calls `onApply` only when the config really changed.
    func reload(_ load: ConfigLoad) {
        let next = ConfigReload.next(lastGood: config, load: Self.checked(load))
        setNote(next.note)
        guard next.config != config else { return }
        let old = config
        config = next.config
        onApply?(old, next.config)
    }

    func save(set: [String: Any], remove: [String] = []) {
        do {
            let data = try ConfigStore.merge(set: set, remove: remove, into: configURL)
            watcher?.noteOwnWrite(data)
            reload(ConfigStore.load(configURL))
        } catch {
            setNote("Couldn't save config.json: \(error.localizedDescription)")
        }
    }

    /// Settings' "Send a test ask": project "Hook", one `echo relay-ok` step and
    /// a verify step, through the current source.
    func sendTestAsk() async -> TestAskResult {
        guard let store else { return .failed("Hook isn't ready yet") }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss"
        let instructable: [String: Any] = [
            "v": 1,
            "title": "Test ask (\(formatter.string(from: Date())))",
            "why": "Checks that asks reach Hook.",
            "urgency": "today",
            "steps": [[
                "do": "Run this in Terminal",
                "where": "Terminal",
                "code": "echo relay-ok",
                "lang": "bash",
                "expect": "relay-ok",
            ]],
            "verify": ["do": "Press Done on this ask in Hook"],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: instructable, options: [.sortedKeys]) else {
            return .failed("Couldn't build the test ask")
        }
        do {
            let result = try await store.post(project: "Hook", instructable: data)
            return result.deduped ? .alreadyWaiting(id: result.item.id) : .sent(id: result.item.id)
        } catch {
            return .failed(UserFacingError.text(error))
        }
    }

    func setShortcutLabel(_ label: String?) {
        guard shortcutLabel != label else { return }
        shortcutLabel = label
    }

    func setListenerState(_ state: ListenerState) {
        guard listenerState != state else { return }
        listenerState = state
    }

    /// The Connect tab's "MCP last call": polls `LocalAPI.lastSeen()` every 5 s while on.
    func setLastSeenPolling(_ on: Bool) {
        lastSeenTask?.cancel()
        lastSeenTask = nil
        guard on else { return }
        lastSeenTask = Task { [weak self] in
            while !Task.isCancelled {
                if let api = self?.localAPI {
                    let seen = await api.lastSeen()
                    if self?.lastSeen != seen {
                        self?.lastSeen = seen
                        self?.refreshSettings()   // the Connect tab reads the snapshot, not lastSeen
                    }
                }
                try? await Task.sleep(for: Self.lastSeenPoll)
            }
        }
    }

    private func setNote(_ note: String?) {
        guard configNote != note else { return }
        configNote = note
        onNoteChange?(note)
    }

    /// A config that parses but resolves to an invalid source is reported like
    /// invalid JSON.
    static func checked(_ load: ConfigLoad) -> ConfigLoad {
        if case .loaded(let config) = load, case .invalid(let reason) = config.resolvedSource() {
            return .unreadable(reason)
        }
        return load
    }
}
