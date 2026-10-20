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
        var problems: [String] = []
        if let configNote { problems.append(UserFacingError.text(configNote)) }
        if let listenerNote { problems.append(UserFacingError.text(listenerNote)) }
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
                skillError: skillError),
            localQueuePath: (dataDirectory.appending(path: "queue.json").path as NSString).abbreviatingWithTildeInPath,
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
            if let path = Self.chooseTokenFile() { draft.tokenFile = (path as NSString).abbreviatingWithTildeInPath }
        case .chooseRepoFolder:
            if let path = Self.chooseFolder() { save(set: ["repoPath": path]) }
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
        }
        refreshSettings()
    }

    /// Saves the draft as the mailbox source.
    func connect() async -> String? {
        let address = draft.address.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = (draft.tokenFile.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
        let context = draft.context.trimmingCharacters(in: .whitespacesAndNewlines)
        var set: [String: Any] = ["source": SourceKind.mailbox.rawValue, "mailboxURL": address, "tokenFile": token]
        if !context.isEmpty { set["context"] = context }
        save(set: set, remove: context.isEmpty ? ["context"] : [])
        return configNote.map { UserFacingError.text($0) }
    }

    /// Settings closed: stop polling the Connect tab's last call.
    func settingsWindowClosed() {
        setLastSeenPolling(false)
    }

    func refreshPermission() async {
        permission = await notifier?.permission() ?? .notDetermined
        refreshSettings()
    }

    /// Title "Relay", body "Notifications work.", ignoring Away (it skips the Notifier's quiet mode).
    private func sendTestNotification() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let note = UNMutableNotificationContent()
        note.title = "Relay"
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
        case .queue:
            if let store { return SettingsWindowController.hosting(QueueTab(model: self, store: store)) }
        case .notifications:
            if let notifier { return SettingsWindowController.hosting(NotificationsTab(model: self, notifier: notifier)) }
        case .connect:
            return SettingsWindowController.hosting(ConnectTab(model: self))
        }
        return NSHostingController(rootView: EmptyView())
    }

    /// The token file's path. The panel never reads the file.
    static func chooseTokenFile() -> String? {
        let panel = NSOpenPanel()
        panel.title = "Choose the token file"
        panel.message = "Relay reads this file only to talk to the mailbox and never shows what it holds."
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
        panel.title = "Choose the Relay repo folder"
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
