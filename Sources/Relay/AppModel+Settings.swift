import AppKit
import RelayCore
import RelayUI
import SwiftUI
import UserNotifications

/// What only AppDelegate can do for Settings and Welcome.
struct SettingsHooks {
    var redock: @MainActor () -> Void = {}
    var showAsk: @MainActor (String) -> Void = { _ in }
    var showPanel: @MainActor () -> Void = {}
    var switchTab: @MainActor (SettingsTabID) -> Void = { _ in }
    /// Registers a shortcut ("" turns it off); false when macOS refused it.
    var applyShortcut: @MainActor (String) -> Bool = { _ in false }
    var suspendShortcut: @MainActor () -> Void = {}
    var resumeShortcut: @MainActor () -> Void = {}
    var checkMailbox: @MainActor () -> Void = {}
    var updateMailbox: @MainActor () -> Void = {}
    var checkForUpdates: @MainActor () -> Void = {}
}

extension AppModel: SettingsViewModel {
    var ownerKeyState: OwnerKeyState { ownerKey?.state ?? .notSetUp }
    var ownerStatus: OwnerStatus? { ownerKey?.status }
    var requireOffPending: Bool { ownerKey?.requireOffPending ?? false }
    var requireProblem: String? { ownerKey?.requireProblem }
    var canRequireOwnerKey: Bool { ownerKey?.canRequireOwnerKey ?? false }
    func setUpOwnerKey() { ownerKey?.setUp() }
    func cancelOwnerKeySetup() { ownerKey?.cancelSetup() }
    func requireOwnerKey(_ on: Bool) { ownerKey?.requireOwnerKey(on) }
    func refreshOwnerStatus() { ownerKey?.refresh() }

    /// Rebuilds `settings` from the config, the Store, presence and the shortcut.
    /// AppDelegate calls it after every Store change, apply, presence and shortcut change.
    func refreshSettings() {
        let home = Self.home
        for screen in NSScreen.screens {
            if let id = screen.displayUUID { displayNames[id] = screen.localizedName }
        }
        let repo = config?.repoPath?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let problems = ConnectionStatus.problems(configNote: configNote, listenerNote: listenerNote)
        let sourceKey = store?.sourceKey ?? SourceKey.none
        var next = SettingsSnapshot(
            config: config,
            readOnly: config == nil || configNote?.hasPrefix("config.json ") == true,
            version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—",
            shortcutLabel: shortcutLabel, shortcutProblem: shortcutProblem,
            presenceLine: presenceLine, away: away,
            login: LoginState(on: LaunchAgent.isInstalled, error: loginError, needsApproval: false),
            displays: settingsDisplays(),
            sourceKey: sourceKey,
            connection: ConnectionStatus.line(
                sourceKey: sourceKey, reachable: store?.reachable ?? false, loadedOnce: store?.lastListAt != nil,
                waiting: store?.items.count ?? 0, problem: store?.problem),
            connectionProblems: problems, permission: permission,
            agents: AgentsState(
                repoPath: repo, lastCall: lastSeen["mcp"], status: agentsStatus, running: agentsRunning.first,
                error: agentsError, pieceErrors: agentsPieceErrors, result: agentsResult),
            localQueuePath: (dataDirectory.appending(path: "queue.json").path as NSString).abbreviatingWithTildeInPath,
            terminals: settingsTerminals(),
            mailbox: sourceKey.hasPrefix("mailbox:") ? mailboxLine : nil,
            documentAppName: documentAppName(),
            install: InstallKind.detect(repoPath: repo, fileExists: { FileManager.default.fileExists(atPath: $0) })
                .line(home: home.path),
            privacy: PrivacyLine.make(config: config, ownerKey: ownerKeyState, logSize: HookLog.size),
            now: settings.now)
        guard next != settings else { return }
        next.now = Date()
        settings = next
    }

    /// "Main display", then each connected display by name; a pinned display that is gone
    /// stays listed as not connected.
    func settingsDisplays() -> [DisplayOption] {
        DisplayChoice.options(screens: NSScreen.dockScreens, names: displayNames, pinned: config?.sidebarDisplay)
    }

    /// Automatic plus the installed terminals. Launch Services is asked at most once a minute,
    /// since this runs after every Store change.
    func settingsTerminals() -> [TerminalChoice] {
        if terminalsCheckedAt.map({ Date().timeIntervalSince($0) > 60 }) ?? true {
            installedTerminals = SessionLauncher.installed()
            terminalsCheckedAt = Date()
        }
        return TerminalChoice.options(installed: installedTerminals,
                                      current: config?.terminal ?? RelayConfig.automaticTerminal)
    }

    /// The app "Open documents in" names, by its display name; nil for the viewer, the
    /// default app, or an app that isn't installed.
    func documentAppName() -> String? {
        guard case .app(let id) = DocumentTarget(config: config?.openDocumentsIn),
              let app = DocumentApps.url(for: id) else { return nil }
        return DocumentApps.name(app)
    }

    func perform(_ action: SettingsAction) {
        switch action {
        case .showConfigInFinder:
            NSWorkspace.shared.activateFileViewerSelecting([configURL])
        case .showLogInFinder:
            let log = HookLog.directory.appending(path: "hook.log")
            if FileManager.default.fileExists(atPath: log.path) {
                NSWorkspace.shared.activateFileViewerSelecting([log])
            } else {
                NSWorkspace.shared.open(HookLog.directory)
            }
        case .showQueueInFinder:
            let queue = dataDirectory.appending(path: "queue.json")
            if FileManager.default.fileExists(atPath: queue.path) {
                NSWorkspace.shared.activateFileViewerSelecting([queue])
            } else {
                NSWorkspace.shared.open(dataDirectory)
            }
        case .chooseTokenFile:
            if let path = Self.chooseTokenFile() { draft.tokenFile = TildePath.abbreviate(path, home: Self.home.path) }
        case .chooseRepoFolder:
            if let path = Self.chooseFolder() {
                if ConnectInfo.isRepo(path, fileExists: { FileManager.default.fileExists(atPath: $0) }) {
                    save(set: ["repoPath": path])
                    Task { @MainActor in await refreshAgents() }
                } else {
                    let alert = NSAlert()
                    alert.messageText = "That folder isn't the Hook repo."
                    alert.informativeText = "It has no mcp/relay_mcp.py."
                    alert.runModal()
                }
            }
        case .redockNow:
            hooks.redock()
        case .requestNotifications:
            Task { @MainActor in
                await notifier?.requestAuthorization()
                await refreshPermission()
            }
        case .openNotificationSettings:
            var text = "x-apple.systempreferences:com.apple.Notifications-Settings.extension"
            if let id = Bundle.main.bundleIdentifier { text += "?id=\(id)" }
            if let url = URL(string: text) { NSWorkspace.shared.open(url) }
        case .sendTestNotification:
            sendTestNotification()
        case .openLoginItems:
            if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
                NSWorkspace.shared.open(url)
            }
        case .setLogin(let on):
            do {
                if on { try LaunchAgent.install(appPath: Bundle.main.bundlePath) } else { try LaunchAgent.remove() }
                loginError = nil
            } catch {
                loginError = "Couldn't change the login item. " + UserFacingError.text(error)
            }
        case .beginShortcut:
            shortcutProblem = nil
            hotKeys?.onResumeFailed = { [weak self] in
                self?.shortcutProblem = .resumeFailed
                self?.refreshSettings()
            }
            hooks.suspendShortcut()
        case .recordShortcut(let spec):
            let registered = spec.map { hooks.applyShortcut($0.canonical) } ?? false
            shortcutProblem = ShortcutProblem.forRecording(spec, registered: registered)
            if registered, let spec { save(set: ["hotkey": spec.canonical]) } else { hooks.resumeShortcut() }
        case .cancelShortcut:
            hooks.resumeShortcut()
        case .clearShortcut:
            _ = hooks.applyShortcut("")
            shortcutProblem = nil
            save(set: ["hotkey": ""])
        case .showAsk(let id):
            hooks.showAsk(id)
        case .switchTab(let tab):
            hooks.switchTab(tab)
        case .showPanel:
            hooks.showPanel()
        case .refreshAgents:
            Task { @MainActor in await refreshAgents() }
        case .integration(let command):
            Task { @MainActor in _ = await runIntegration(command) }
        case .agentAction(let action):
            switch action {
            case .openAsk(let id):
                hooks.showAsk(id)
            case .reveal(let path):
                let url = URL(fileURLWithPath: ConnectInfo.normalized(path))
                if FileManager.default.fileExists(atPath: url.path) {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } else {
                    NSWorkspace.shared.open(url.deletingLastPathComponent())
                }
            case .setUp, .update:
                if let command = action.command { Task { @MainActor in _ = await runIntegration(command) } }
            }
        case .copyText(let text):
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        case .openDonation:
            if let url = ConnectInfo.donationLink() { NSWorkspace.shared.open(url) }
        case .checkMailbox:
            hooks.checkMailbox()
        case .updateMailbox:
            hooks.updateMailbox()
        case .checkForUpdates:
            hooks.checkForUpdates()
        case .chooseDocumentApp:
            if let app = DocumentApps.choose(title: "Choose the app for documents") {
                save(set: ["openDocumentsIn": DocumentApps.configValue(for: app)])
            }
        }
        refreshSettings()
    }

    // MARK: Agents (relay integrations)

    /// Runs one `relay integrations` command, then reads the status again. A failed Fix…
    /// command's line goes on its piece row; any other on the pane.
    @discardableResult
    func runIntegration(_ command: IntegrationCommand) async -> Result<Data, IntegrationError> {
        let row = AgentsState.key(for: command)
        if let row { agentsPieceErrors[row] = nil }
        if command != .status { agentsResult = nil }
        agentsRunning.append(command)
        refreshSettings()
        let result = await integrations.run(command)
        if let index = agentsRunning.firstIndex(of: command) { agentsRunning.remove(at: index) }
        switch result {
        case .success(let data):
            if row == nil { agentsError = nil }
            if command == .reinstall(harness: nil, piece: nil, force: false) {
                agentsResult = (try? IntegrationReport.decode(data))?.reinstallLine
            }
        case .failure(let error):
            if let row { agentsPieceErrors[row] = error.text } else { agentsError = error.text }
        }
        if command != .status { await refreshAgents() }
        refreshSettings()
        return result
    }

    /// Show Difference: runs `diff` (its failure lands on the piece row) and decodes it.
    func integrationDiff(harness: String, piece: String) async -> Result<IntegrationDiff, IntegrationError> {
        switch await runIntegration(.diff(harness: harness, piece: piece)) {
        case .success(let data):
            guard let diff = try? IntegrationDiff.decode(data) else {
                agentsPieceErrors[AgentsState.key(harness: harness, piece: piece)] = IntegrationError.unreadable.text
                refreshSettings()
                return .failure(.unreadable)
            }
            return .success(diff)
        case .failure(let error):
            return .failure(error)
        }
    }

    /// Reads `relay integrations status` and offers any new harness in a Notice.
    func refreshAgents() async {
        switch await integrations.status() {
        case .success(let status):
            agentsStatus = status
            agentsError = nil
            noticeNewAgents(status)
        case .failure(let error):
            // No repo yet is what the Hook repo row already says.
            agentsError = error == .notInstalled && config?.repoPath == nil ? nil : error.text
        }
        refreshSettings()
    }

    /// The scheduled sync: `--if-changed` at launch, a plain one once a day. New harnesses
    /// are set up when "Set up new agents automatically" is on (the manifest decides when
    /// no status has been read yet).
    func syncAgents(ifChanged: Bool) async {
        agentsSyncStarted = Date()
        await runIntegration(.sync(ifChanged: ifChanged, includeNew: agentsStatus?.autoSetup ?? false, harness: nil))
    }

    /// A day since the last sync, by the manifest or by this run's last attempt.
    func agentsSyncDue(now: Date = Date()) -> Bool {
        IntegrationSchedule.dailyDue(lastSync: [agentsStatus?.lastSync, agentsSyncStarted].compactMap { $0 }.max(),
                                     now: now)
    }

    /// With automatic setup off: one info Notice for the harnesses found and not set up,
    /// unless each was offered already in this run or dismissed before.
    private func noticeNewAgents(_ status: IntegrationStatus) {
        let ids = IntegrationNotice.ids(status: status, dismissed: IntegrationNotice.dismissed(in: .standard))
        guard !ids.isEmpty, !Set(ids).isSubset(of: agentsNoticed), let store else { return }
        agentsNoticed.formUnion(ids)
        store.post(.newAgents(ids: ids, names: IntegrationNotice.names(ids: ids, status: status)))
    }

    /// Validates and saves the draft, then waits up to 10 s for the new source's first list.
    func connect() async -> String? {
        let errors = draft.errors()
        if let first = errors.address ?? errors.tokenFile { return first }
        let change = draft.changes(home: Self.home.path)
        save(set: change.set, remove: change.remove)
        if let note = configNote, note.hasPrefix("Couldn't save") { return UserFacingError.text(note) }
        guard case .mailbox(let settings)? = config?.resolvedSource() else { return configNote.map { UserFacingError.text($0) } }
        let key = SourceKey.mailbox(settings)
        let deadline = Date().addingTimeInterval(MailboxDraft.connectTimeout)
        while Date() < deadline {
            if let store, store.sourceKey == key {
                if store.reachable { return nil }
                if let problem = store.problem { return UserFacingError.text(problem) }
            }
            try? await Task.sleep(for: Self.connectPoll)
        }
        return MailboxDraft.noAnswer
    }

    /// Unsaved values stay until the Settings window closes.
    func resetDraft() {
        draft = MailboxDraft(config: config, home: Self.home.path)
    }

    /// Settings closed: stop polling Settings › Agents' MCP last call.
    func settingsWindowClosed() {
        setLastSeenPolling(false)
        resetDraft()
    }

    func refreshPermission() async {
        permission = await notifier?.permission() ?? .notDetermined
        refreshSettings()
    }

    /// Title "Hook", body "Notifications work.", ignoring Away (it skips the Notifier's quiet mode).
    private func sendTestNotification() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let note = UNMutableNotificationContent()
        note.title = "Hook"
        note.body = "Notifications work."
        if config?.notify.sound == true { note.sound = .default }
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "relay.test.\(UUID().uuidString)", content: note, trigger: nil))
    }

    /// One tab's content: each case builds one tab, so a tab's view changes here only.
    func settingsTab(_ tab: SettingsTabID) -> NSViewController {
        switch tab {
        case .general: return SettingsWindowController.hosting(GeneralTab(model: self))
        case .panel: return SettingsWindowController.hosting(PanelTab(model: self))
        case .queue: return SettingsWindowController.hosting(QueueTab(model: self))
        case .notifications:
            if permissionObserver == nil { watchPermission() }
            Task { @MainActor in await refreshPermission() }
            return SettingsWindowController.hosting(NotificationsTab(model: self))
        case .agents:
            Task { @MainActor in await refreshAgents() }
            return SettingsWindowController.hosting(AgentsTab(model: self))
        }
    }

    /// Settings → Notifications opened, or Hook became active: macOS may have changed it.
    func watchPermission() {
        permissionObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task { @MainActor in await self.refreshPermission() }
            }
        }
    }

    /// The token file's path. The panel never reads the file.
    static func chooseTokenFile() -> String? {
        let panel = NSOpenPanel()
        panel.title = "Choose the token file"
        panel.message = "Hook reads this file only to talk to the Pond and never shows what it holds."
        panel.prompt = "Choose"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.treatsFilePackagesAsDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return url.path
    }

    static func chooseFolder() -> String? {
        let panel = NSOpenPanel()
        panel.title = "Choose the Hook repo folder"
        panel.prompt = "Choose"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return url.path
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
