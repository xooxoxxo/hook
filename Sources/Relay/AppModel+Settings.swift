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
}

extension AppModel: SettingsViewModel {
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
            repo: RepoState(
                repoPath: repo, mcpCommand: repo.map { ConnectInfo.mcpCommand(repoPath: $0) },
                claudeMdAvailable: repo.flatMap { ConnectInfo.claudeMdSection(repoPath: $0) } != nil,
                skill: repo.map { ConnectInfo.skillState(home: home, repoPath: $0) },
                cliFound: ConnectInfo.cliInstalled(home: home), lastCall: lastSeen["mcp"],
                skillError: skillError, mcpRegistered: mcpRegistered, mcpBusy: mcpBusy, mcpError: mcpError,
                hookInstalled: hookInstalled, hookError: hookError, claudeMdInstalled: claudeMdInstalled),
            localQueuePath: (dataDirectory.appending(path: "queue.json").path as NSString).abbreviatingWithTildeInPath,
            terminals: settingsTerminals(),
            mailbox: sourceKey.hasPrefix("mailbox:") ? mailboxLine : nil,
            documentAppName: documentAppName(),
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
                    skillError = nil   // it was about the old repo
                    save(set: ["repoPath": path])
                } else {
                    let alert = NSAlert()
                    alert.messageText = "That folder isn't the Hook repo."
                    alert.informativeText = "It has no mcp/relay_mcp.py."
                    alert.runModal()
                }
            }
        case .installSkill:
            if let repo = settings.repo.repoPath {
                do {
                    try ConnectInfo.installSkill(home: Self.home, repoPath: repo)
                    skillError = nil
                } catch {
                    skillError = "Couldn't install the skill. " + UserFacingError.text(error)
                }
            }
        case .copyClaudeMdSection:
            if let repo = settings.repo.repoPath, let text = ConnectInfo.claudeMdSection(repoPath: repo) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
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
        case .checkAgents:
            checkAgents()
        case .registerMCP:
            registerMCP()
        case .installRepliesHook:
            do {
                try ConnectInfo.installRepliesHook(home: Self.home)
                hookError = nil
            } catch {
                hookError = "Couldn't add the hook. " + UserFacingError.text(error)
            }
            checkAgents()
        case .copyText(let text):
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        case .openDonation:
            if let url = ConnectInfo.donationLink() { NSWorkspace.shared.open(url) }
        case .checkMailbox:
            hooks.checkMailbox()
        case .updateMailbox:
            hooks.updateMailbox()
        case .chooseDocumentApp:
            if let app = DocumentApps.choose(title: "Choose the app for documents") {
                save(set: ["openDocumentsIn": DocumentApps.configValue(for: app)])
            }
        }
        refreshSettings()
    }

    /// Re-reads ~/.claude.json, settings.json and CLAUDE.md for the agents page. The reads
    /// run off the main actor (~/.claude.json can be large); the results land on it, and only
    /// the newest check's do. `mcpKnown` keeps the MCP item done whatever the file says
    /// (a registration that just worked, in case claude keeps its servers elsewhere).
    func checkAgents(mcpKnown: Bool = false) {
        let home = Self.home, repo = config?.repoPath
        agentCheckGeneration += 1
        let generation = agentCheckGeneration
        Task { @MainActor [weak self] in
            let checks = await Task.detached(priority: .userInitiated) {
                ConnectInfo.agentChecks(home: home, repoPath: repo)
            }.value
            guard let self, generation == self.agentCheckGeneration else { return }
            self.mcpRegistered = checks.mcpRegistered || mcpKnown
            self.hookInstalled = checks.hookInstalled
            self.claudeMdInstalled = checks.claudeMdInstalled
            self.refreshSettings()
        }
    }

    /// Register: `claude mcp add` in the login shell, off the main actor, with a time cap.
    private func registerMCP() {
        guard !mcpBusy, let repo = settings.repo.repoPath else { return }
        mcpBusy = true
        mcpError = nil
        let command = ConnectInfo.mcpShellCommand(repoPath: repo)
        Task { @MainActor in
            let outcome = await LoginShell.run(command)
            mcpBusy = false
            mcpError = outcome.ok ? nil : "Couldn't register: " + LoginShell.failureLine(outcome) + ". Copy the command and run it in Terminal."
            if outcome.ok { mcpRegistered = true }   // in case claude keeps its servers elsewhere
            checkAgents(mcpKnown: outcome.ok)
            refreshSettings()
        }
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

    /// Settings closed: stop polling the Connect tab's last call.
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
        case .connect: return SettingsWindowController.hosting(ConnectTab(model: self))
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
        panel.message = "Hook reads this file only to talk to the mailbox and never shows what it holds."
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
