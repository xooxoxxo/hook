import AppKit
import SwiftUI
import RelayCore
import RelayUI

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    /// The longest a quit waits for held closes to reach the source.
    static let quitDrainTimeout: Duration = .seconds(3)
    /// How long a copy that handed off waits to see the running copy stay; longer than a quit takes.
    static let handOffGrace: Duration = quitDrainTimeout + .seconds(1)

    private var model: AppModel?
    private var store: Store?
    private var panel: SidePanel?
    private var panelKeyObserver: (any NSObjectProtocol)?
    private var hotKeys: HotKeyManager?
    private var settings: SettingsWindowController?
    private var welcome: WelcomeWindowController?
    private var notifier: Notifier?
    private var menuBar: MenuBarController?
    /// Asks that arrived while the panel was hidden and haven't been seen: the menu-bar dot.
    private var unseen = UnseenAsks.load(.standard)
    private var server: LoopbackServer?
    private var serverPort: Int?
    private let routing = ServerRouting()
    /// Created on first use of the local source and kept for the app's lifetime.
    private var localQueue: LocalQueue?
    private var localAPI: LocalAPI?
    private var localAPIPort: Int?
    /// "Relay is already running", or why the local queue or token isn't available.
    private var localProblem: String?
    /// Where a corrupt queue.json was moved; posted as a Notice once the store shows the local queue,
    /// because the swap clears any Notice posted before it.
    private var queueMovedPath: String?
    private var applied: SourceIdentity?
    /// The config the panel was last docked for; `applyPanelSettings` docks only when it moves the panel.
    private var dockedConfig: RelayConfig?
    private var dockedOnce = false
    /// Config applies run one after another (opening the queue is async).
    private var applyChain: Task<Void, Never>?
    /// A link that arrived before launch finished.
    private var pendingLink: String?
    /// A relay://show that arrived before launch finished.
    private var pendingShow = false
    /// Quit is waiting on held-back closes; set once the reply has been sent.
    private var terminationAnswered = false
    /// Away mode: the signals, the flag file and the asks counted while away.
    private let presence = PresenceMonitor()
    private var awayTally = AwayTally()
    /// The first ask that arrived while away; the return summary click selects it.
    private var awayFirstID: String?
    /// What the last Settings rebuild read from the Store.
    private var settingsStoreInputs: SettingsStoreInputs?
    /// Open (or held for Undo or sending) and Recently closed ids at the last Store change.
    private var lastOpenIDs: Set<String> = []
    private var lastClosedIDs: Set<String> = []
    /// SIGTERM (`kill`, `launchctl bootout`) skips applicationWillTerminate, so it
    /// is caught here to clear the away flag first.
    private var termSource: (any DispatchSourceSignal)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if handOffToRunningRelay() { return }
        startUp()
    }

    /// Everything after the single-instance check: the model, panel, menu bar, presence and the first apply.
    private func startUp() {
        let hotKeys = HotKeyManager { [weak self] in self?.togglePanel() }
        hotKeys.onLabelChange = { [weak self] in self?.updateShortcutLabel() }
        self.hotKeys = hotKeys
        let environment = ProcessInfo.processInfo.environment
        let model = AppModel(
            configURL: RelayConfig.path(environment: environment),
            dataDirectory: AppModel.dataDirectory(environment: environment))
        let store = Store()
        model.store = store
        self.model = model
        self.store = store
        model.hotKeys = hotKeys
        settings = SettingsWindowController(model: model)

        panel = makePanel(store: store, model: model)

        setUpMenuBar()
        store.onStateChange = { [weak self] in self?.storeStateChanged() }
        store.onNewItems = { [weak self] items in
            self?.noteArrivals(items)
            self?.announce(items)
        }
        // A click goes through the same check as a link: closed or unknown → Notice.
        let notifier = Notifier { [weak self] id in self?.openLink(id) }
        notifier.onOpenList = { [weak self] first in
            guard let self, let store = self.store else { return }
            if store.navigation.selectedID != nil { store.back() }
            if let first { store.listSelection = first }
            self.panel?.present(focus: true, animated: true)
            self.refreshIfStale()
        }
        self.notifier = notifier
        model.notifier = notifier
        model.hooks = SettingsHooks(
            redock: { [weak self] in self?.panel?.redock() },
            showAsk: { [weak self] id in self?.showItem(id) },
            showPanel: { [weak self] in self?.panel?.present(focus: true, animated: true) },
            switchTab: { [weak self] tab in self?.settings?.show(tab: tab) },
            applyShortcut: { [weak hotKeys] raw in hotKeys?.apply(raw) ?? false },
            suspendShortcut: { [weak hotKeys] in hotKeys?.suspend() },
            resumeShortcut: { [weak hotKeys] in hotKeys?.resume() })
        store.onCloseSent = { [weak self] id in self?.notifier?.remove(ids: [id]) }

        model.onApply = { [weak self] _, new in
            self?.scheduleApply(new)
            self?.applyGeneral(new)
        }
        model.onNoteChange = { [weak self] note in
            self?.configNoteChanged(note)
        }
        switch model.start() {
        case .missing:
            showWelcome()
        case .unreadable:
            settings?.show(tab: .queue)
        case .loaded(let config):
            if config.resolvedSource() == .incomplete { showWelcome() }
        }
        configNoteChanged(model.configNote)
        presence.onChange = { [weak self] status in
            self?.presenceChanged(to: status)
        }
        presence.start(
            mode: model.config?.presence ?? .auto,
            awayAfterMinutes: model.config?.awayAfterMinutes ?? PresenceLogic.defaultAwayAfterMinutes)
        presenceChanged(to: presence.status)
        watchTermSignal()
        applyGeneral(model.config)
        scheduleApply(model.config)

        // A link that launched the app is checked against the configured source, so it
        // waits for the first apply (the source swap is async).
        Task { @MainActor [weak self] in
            await self?.applyChain?.value
            guard let self, let id = self.pendingLink else { return }
            self.pendingLink = nil
            self.openLink(id)
        }
        if pendingShow {
            pendingShow = false
            panel?.present(focus: true, animated: true)
        }
    }

    /// A second copy (another path, or a manual `open -n`) hands `relay://show` to the
    /// copy that started first and exits before it opens the queue, the port or the status
    /// item. Only an earlier copy counts, so two copies started together never both leave.
    private func handOffToRunningRelay() -> Bool {
        guard let bundleID = Bundle.main.bundleIdentifier else { return false }
        let myPID = ProcessInfo.processInfo.processIdentifier
        let running = NSWorkspace.shared.runningApplications.map {
            SingleInstance.Copy(bundleID: $0.bundleIdentifier, pid: $0.processIdentifier,
                                started: Self.startTime(of: $0.processIdentifier))
        }
        let mine = SingleInstance.Copy(bundleID: bundleID, pid: myPID, started: Self.startTime(of: myPID))
        guard let pid = SingleInstance.older(than: mine, running: running),
              let other = NSRunningApplication(processIdentifier: pid), let appURL = other.bundleURL,
              let show = URL(string: "relay://show") else { return false }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        NSWorkspace.shared.open([show], withApplicationAt: appURL, configuration: configuration) { _, error in
            if let error { NSLog("Relay: hand-off to running copy failed: %@", error.localizedDescription) }
            Task { @MainActor [weak self] in await self?.leaveUnlessQuit(pid) }
        }
        return true
    }

    /// Exits once the copy this one handed off to has stayed up for `handOffGrace`. A copy
    /// that was quitting (an update, or a quit still sending held closes) is gone by then,
    /// and this copy starts instead, so a launch during a quit never leaves no Relay running.
    private func leaveUnlessQuit(_ pid: pid_t) async {
        func gone() -> Bool { NSRunningApplication(processIdentifier: pid)?.isTerminated ?? true }
        let deadline = ContinuousClock.now + Self.handOffGrace
        while !gone(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard gone() else { exit(0) }
        NSLog("Relay: the running copy quit during the hand-off; starting")
        startUp()
    }

    /// When a process started, from the kernel. Launch Services' `launchDate` is nil for
    /// a copy started without it (a binary run directly), so it can't order every copy.
    private static func startTime(of pid: pid_t) -> Date? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970: TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1_000_000)
    }

    /// Held-back Done and Skip are sent before quitting, with a 3 s cap so
    /// quitting never hangs on an unreachable source.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let store, store.hasPendingCloses else { return .terminateNow }
        terminationAnswered = false
        store.sendingCloses = store.pending.count
        Task {
            await store.sendAllPending()
            answerTermination()
        }
        Task {
            try? await Task.sleep(for: Self.quitDrainTimeout)
            answerTermination()
        }
        return .terminateLater
    }

    /// A normal quit or SIGTERM removes the away flag; after a crash it stays
    /// until the next launch rewrites or removes it.
    func applicationWillTerminate(_ notification: Notification) {
        presence.stop()
    }

    private func watchTermSignal() {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                self?.presence.stop()
                // terminate(_:) waits in a nested event loop while held closes are sent. Inside
                // this main-queue handler that loop can't run main-queue work, so the send never
                // finished and Relay never quit; from a run-loop block it can.
                RunLoop.main.perform { MainActor.assumeIsolated { NSApp.terminate(nil) } }
            }
        }
        source.resume()
        termSource = source
    }

    private func answerTermination() {
        guard !terminationAnswered else { return }
        terminationAnswered = true
        store?.sendingCloses = 0
        NSApp.reply(toApplicationShouldTerminate: true)
    }

    /// relay://show and relay://i/<uuid>.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            switch RelayURL.parse(url) {
            case .show:
                if let panel { panel.present(focus: true, animated: true) } else { pendingShow = true }
            case .open(let id):
                openLink(id)
            case nil:
                break
            }
        }
    }

    /// A link from outside the app (relay://, the loopback server, a notification click)
    /// opens an ask in the open queue. An ask confirmed closed shows the list with
    /// "This ask is no longer open."; one that couldn't be checked (no source yet,
    /// a check in the last 5 seconds, an unreachable source) opens directly, and the
    /// detail's not-found view covers it if it is really gone. A config apply still
    /// running is waited for first, so the check runs against the applied source.
    func openLink(_ id: String) {
        guard let store else {
            pendingLink = id
            return
        }
        Task { [weak self] in
            await self?.applyChain?.value
            guard let self else { return }
            switch await store.checkLink(id) {
            case .open, .unknown:
                self.showItem(id)
            case .closed:
                self.showNoLongerOpen(id)
            }
        }
    }

    private func showNoLongerOpen(_ id: String) {
        guard let store, let panel else { return }
        if store.navigation.selectedID != nil { store.back() }
        panel.present(focus: true, animated: true)
        store.post(.noLongerOpen(id: id, canShowClosed: store.recentlyClosed.contains { $0.id == id }))
    }

    func showItem(_ id: String) {
        guard let store, let panel else { return }
        panel.show()
        refreshIfStale()
        Task { await store.focus(id) }
    }

    // MARK: Panel

    /// The side panel around PanelRoot. Keys go through PanelKeyRouter;
    /// the panel's own actions (hide, dock, Settings, copy, open) come back here.
    private func makePanel(store: Store, model: AppModel) -> SidePanel {
        let ref = PanelRef()
        let hosting = NSHostingView(rootView: PanelRoot(model: store).environment(\.panelDragActions, .panel(ref)))
        hosting.sizingOptions = []
        // No title-bar inset: the content starts at the panel's top edge.
        hosting.safeAreaRegions = []
        let panel = SidePanel(content: hosting)
        ref.panel = panel
        panel.onShown = { [weak self] in self?.panelShown() }
        panel.connect(model)
        panel.keyRouter = PanelKeyRouter(model: store)
        store.shell = PanelShellActions(
            hide: { [weak self] in self?.panel?.hide(animated: true) },
            setUp: { [weak self] in self?.setUp() },
            quit: { NSApp.terminate(nil) },
            dock: { [weak self] edge in self?.panel?.dock(edge) },
            openSettings: { [weak self] tab in self?.showSettings(tab: tab) },
            copy: { text in
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            },
            openURL: { url in NSWorkspace.shared.open(url) })
        // The two shell hooks the Store calls: VoiceOver's "Ask reopened", and the queueMoved Notice's Show in Finder.
        store.onAnnounce = { text in AccessibilityNotification.Announcement(text).post() }
        store.onShowInFinder = { path in
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        }
        // Whenever the panel becomes key, the selection is the last one if still shown, else the first row.
        panelKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.store?.settleSelection() }
        }
        return panel
    }

    /// Settings on a tab, or on the remembered one when nil.
    private func showSettings(tab: SettingsTabID?) {
        settings?.show(tab: tab)
    }

    /// `sidebarEdge` and `appearance`.
    private func applyPanelSettings(_ config: RelayConfig?) {
        if !dockedOnce || DockGeometry.needsDock(old: dockedConfig, new: config) {
            panel?.dock(edge: config?.sidebarEdge ?? .right, animated: true)
            dockedOnce = true
        }
        dockedConfig = config
        switch config?.appearance ?? .system {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    // MARK: Applying a config

    private func scheduleApply(_ config: RelayConfig?) {
        let previous = applyChain
        applyChain = Task { [weak self] in
            await previous?.value
            await self?.apply(config)
        }
    }

    /// Source, then port, then reachability.
    private func apply(_ config: RelayConfig?) async {
        guard let model else { return }
        let port = config?.port ?? RelayConfig.defaultPort
        let pollSeconds = config?.pollSeconds ?? RelayConfig.defaultPollSeconds

        switch config?.resolvedSource() ?? .incomplete {
        case .local:
            let keepDays = config?.keepDays ?? RelayConfig.defaultKeepDays
            if let queue = await openLocalQueue(keepDays: keepDays), let token = ensureToken() {
                await queue.setKeepDays(keepDays)
                let api = localAPI(for: queue, port: port, token: token)
                model.localAPI = api
                routing.update(ServerRouting.Routes(source: "local", api: api, token: token))
                swapIfNeeded(SourceIdentity(key: SourceKey.local, mailbox: nil), pollSeconds: pollSeconds) {
                    LocalQueueSource(queue: queue)
                }
                if let moved = queueMovedPath {
                    queueMovedPath = nil
                    store?.post(.queueMoved(path: moved))
                }
            } else {
                model.localAPI = nil
                routing.update(ServerRouting.Routes(source: "none", api: nil, token: nil))
                swapIfNeeded(SourceIdentity(key: SourceKey.none, mailbox: nil), pollSeconds: pollSeconds) { nil }
            }
        case .mailbox(let settings):
            localProblem = nil
            model.localAPI = nil
            routing.update(ServerRouting.Routes(source: "mailbox", api: nil, token: nil))
            let key = SourceKey.mailbox(settings)
            SourceKey.migrate(.standard, from: SourceKey.legacyMailbox(settings), to: key)
            swapIfNeeded(SourceIdentity(key: key, mailbox: settings), pollSeconds: pollSeconds) {
                MailboxClient(settings: settings)
            }
        case .incomplete, .invalid:
            localProblem = nil
            model.localAPI = nil
            routing.update(ServerRouting.Routes(source: "none", api: nil, token: nil))
            swapIfNeeded(SourceIdentity(key: SourceKey.none, mailbox: nil), pollSeconds: pollSeconds) { nil }
        }
        restartServerIfNeeded(port: port)
        updateListenerProblem()
        updateMenuBar()
        applyPanelSettings(config)
        store?.afterClose = config?.afterClose ?? .next
    }

    /// A new identity swaps the source; the same identity only applies the poll interval.
    private func swapIfNeeded(_ next: SourceIdentity, pollSeconds: Int, make: () -> (any QueueSource)?) {
        guard let store else { return }
        guard applied != next else {
            store.setPollInterval(pollSeconds)
            return
        }
        applied = next
        store.swap(to: make(), identity: next, pollSeconds: pollSeconds)
    }

    /// The one `LocalQueue`: opened on first use, then reused. A failed open is
    /// not kept, so the next apply tries again.
    private func openLocalQueue(keepDays: Int) async -> LocalQueue? {
        if let localQueue {
            localProblem = nil
            return localQueue
        }
        guard let model else { return nil }
        let queue = LocalQueue(directory: model.dataDirectory, keepDays: keepDays)
        do {
            let outcome = try await queue.open()
            localQueue = queue
            localProblem = nil
            if case .recovered(let moved) = outcome {
                queueMovedPath = moved
            }
            return queue
        } catch LocalQueueError.locked {
            let text = "Relay is already running"
            localProblem = text
            logProblem(text)
        } catch {
            let reason: String
            if case .storeFailed(let text)? = error as? LocalQueueError {
                reason = text
            } else {
                reason = error.localizedDescription
            }
            let text = "Couldn't open the queue: \(reason)"
            localProblem = text
            logProblem(text)
        }
        return nil
    }

    /// `local-token` next to config.json, created when missing; its value is never kept here.
    private func ensureToken() -> LocalToken? {
        guard let model else { return nil }
        let token = LocalToken(file: model.configURL.deletingLastPathComponent().appending(path: "local-token"))
        do {
            _ = try token.ensure()
            return token
        } catch {
            let text = "Couldn't create the local token at \(token.file.path)"
            localProblem = text
            logProblem(text)
            return nil
        }
    }

    private func localAPI(for queue: LocalQueue, port: Int, token: LocalToken) -> LocalAPI {
        if let localAPI, localAPIPort == port { return localAPI }
        let api = LocalAPI(queue: queue, port: port, token: { try? token.ensure() })
        localAPI = api
        localAPIPort = port
        return api
    }

    // MARK: Loopback server

    private func restartServerIfNeeded(port: Int) {
        guard serverPort != port else { return }
        server?.stop()
        server = nil
        serverPort = port
        guard let value = UInt16(exactly: port) else { return }
        let routing = self.routing
        let server = LoopbackServer(
            port: value,
            onOpen: { [weak self] id in self?.openLink(id) },
            onState: { [weak self] state in self?.listenerChanged(state) },
            health: { nonce in routing.health(port: port, nonce: nonce) },   // this server's own port
            api: { routing.api })
        self.server = server
        server.start()
    }

    private func listenerChanged(_ state: ListenerState) {
        model?.setListenerState(state)
        if case .failed(let text) = state { NSLog("Relay: %@", text) }
        updateListenerProblem()
    }

    /// The status bar's listener line, in every mode. In local mode a queue or token
    /// problem (`localProblem`) comes first; `apply` clears `localProblem` in the other modes.
    private func updateListenerProblem() {
        guard let store, let model else { return }
        if case .local = model.resolvedSource, let localProblem {
            store.setListenerProblem(localProblem)
        } else if case .failed(let text) = model.listenerState {
            store.setListenerProblem(text)
        } else {
            store.setListenerProblem(nil)
        }
    }

    // MARK: Problems

    /// A local-queue problem. It reaches the status bar through `setListenerProblem`
    /// (`localProblem`), once; the log keeps it too.
    private func logProblem(_ text: String) {
        NSLog("Relay: %@", text)
    }

    /// config.json's problem shows in the status bar ("config.json has an error"), once.
    private func configNoteChanged(_ note: String?) {
        store?.setConfigNote(note)
        model?.refreshSettings()
    }

    // MARK: Menu bar

    private func setUpMenuBar() {
        menuBar = MenuBarController(
            inputs: { [weak self] in self?.menuInputs() ?? MenuInputs(
                notSetUp: true, panelVisible: false, shortcut: nil, statusLine: "No queue set up",
                presenceLine: "", presence: .auto, displays: [], pinned: nil) },
            onToggle: { [weak self] in self?.togglePanel() },
            onAction: { [weak self] action in self?.perform(action) })
        MainMenu.install(settings: #selector(showSettings(_:)), target: self)
        updateMenuBar()
        updateShortcutLabel()
    }

    /// What the menu-bar menu shows, read on every open.
    private func menuInputs() -> MenuInputs {
        let status = presence.status
        let label = hotKeys?.label ?? HotKeyManager.offLabel
        let shortcut = label == HotKeyManager.offLabel
            ? nil : HotkeySpec.parse(model?.config?.hotkey ?? HotkeySpec.defaultString)
        return MenuInputs(
            notSetUp: (store?.sourceKey ?? SourceKey.none) == SourceKey.none,
            panelVisible: panel?.isShown ?? false,
            shortcut: shortcut,
            statusLine: MenuStatusLine.text(
                sourceKey: store?.sourceKey ?? SourceKey.none, reachable: store?.reachable ?? false,
                updated: store?.lastListAt.map { ClockText.time($0) }),
            presenceLine: PresenceLogic.statusLine(
                state: status.state, reason: status.reason, since: ClockText.time(status.since)),
            presence: presence.mode,
            displays: NSScreen.screens.compactMap { screen in
                screen.displayUUID.map { MenuDisplay(id: $0, name: screen.localizedName) }
            },
            pinned: model?.config?.sidebarDisplay)
    }

    private func perform(_ action: MenuAction) {
        switch action {
        case .setUp: setUp()
        case .togglePanel: togglePanel()
        case .setPresence(let mode): model?.save(set: ["presence": mode.rawValue])
        case .refresh: refreshNow()
        case .dock(let edge): panel?.dock(edge)
        case .pinDisplay(let id):
            if let id { model?.save(set: ["sidebarDisplay": id]) } else { model?.save(set: [:], remove: ["sidebarDisplay"]) }
        case .redock: panel?.redock()
        case .settings: showSettings(nil)
        case .about:
            NSApp.activate()
            NSApp.orderFrontStandardAboutPanel(nil)
        case .quit: NSApp.terminate(nil)
        }
    }

    /// After every list, close, undo and send. Settings is rebuilt only when what it reads
    /// from the Store changed: the rebuild reads files and screens, and polls mostly change nothing.
    private func storeStateChanged() {
        if let store, store.listLoaded {
            updateUnseen { $0.keep(open: Set(store.items.map(\.id))) }
        }
        updateMenuBar(refreshingSettings: false)
        if let store {
            let inputs = SettingsStoreInputs(store)
            if inputs != settingsStoreInputs {
                settingsStoreInputs = inputs
                model?.refreshSettings()
            }
        }
        cleanUpNotifications()
    }

    /// Badge, dimming, tooltip and VO label, after every Store change.
    private func updateMenuBar(refreshingSettings: Bool = true) {
        guard let store else { return }
        let status = presence.status
        var state = store.menuBarState(unseen: unseen.showsDot, away: status.state == .away)
        let label = hotKeys?.label ?? HotKeyManager.offLabel
        state.shortcut = label == HotKeyManager.offLabel ? nil : label
        state.awaySince = status.state == .away ? ClockText.time(status.since) : nil
        menuBar?.update(state)
        if refreshingSettings { model?.refreshSettings() }
    }

    /// The shortcut's label for the menu bar's tooltip and, mirrored into the model,
    /// the sidebar footer's hint; nil there when off or not registered.
    private func updateShortcutLabel() {
        let label = hotKeys?.label ?? HotKeyManager.offLabel
        updateMenuBar()
        model?.setShortcutLabel(label == HotKeyManager.offLabel ? nil : label)
    }

    /// Settings… from ⌘,, the status-item menu and the sidebar footer.
    @objc func showSettings(_ sender: Any?) {
        settings?.show()
    }

    /// First run, "Set Up Relay…", and the panel's Set Up… before Welcome was finished.
    private func showWelcome() {
        guard let model else { return }
        let welcome = self.welcome ?? WelcomeWindowController(model: model) { [weak self] in
            self?.panel?.present(focus: true, animated: true)
        }
        self.welcome = welcome
        welcome.show()
    }

    /// The Not set up state's Set Up…: Welcome until a config exists, then Settings → Queue.
    /// An unreadable config.json opens Settings → Queue too, never Welcome over the broken file.
    private func setUp() {
        if model?.configNote?.hasPrefix("config.json has an error") == true {
            settings?.show(tab: .queue)
        } else if model?.config?.resolvedSource() == nil || model?.config?.resolvedSource() == .incomplete {
            showWelcome()
        } else {
            settings?.show(tab: .queue)
        }
    }

    // MARK: Global shortcut

    /// The General setting nothing else applies: the global shortcut.
    /// Runs at launch and on every config change; a hotkey the General tab just
    /// registered is the same spec, so `apply` is a no-op then. `appearance` and
    /// `sidebarEdge` are applied at the end of `apply(_:)`.
    private func applyGeneral(_ config: RelayConfig?) {
        presence.configure(
            mode: config?.presence ?? .auto,
            awayAfterMinutes: config?.awayAfterMinutes ?? PresenceLogic.defaultAwayAfterMinutes)
        updatePresenceMenu()
        guard let hotKeys else { return }
        // A later successful apply clears an earlier failure's red line.
        model?.shortcutProblem = hotKeys.apply(config?.hotkey ?? HotkeySpec.defaultString) ? nil : .refused
        updateShortcutLabel()
    }

    @objc private func togglePanel() {
        guard let panel else { return }
        let wasShown = panel.isShown
        panel.toggle()
        if !wasShown, panel.isShown { refreshIfStale() }
    }

    /// Showing the panel in mailbox mode refreshes a list older than 5 s. The rule
    /// is `Store.refreshIfStale()`; this only starts it.
    private func refreshIfStale() {
        guard let store else { return }
        Task { await store.refreshIfStale() }
    }

    private func refreshNow() {
        guard let store else { return }
        Task { await store.refresh() }
    }

    // MARK: Notifications

    /// New asks from the Store diff. While away they are only counted (no banner, no
    /// sound, no slide-in), and only those whose urgency is switched on in Notifications,
    /// so the summary covers what would have notified. Home: notifications per Settings,
    /// and the first "now" ask of the batch, from any project, filtered out or not, slides
    /// the hidden panel in on that ask without focus. A visible panel never moves;
    /// VoiceOver hears about the ask.
    private func announce(_ items: [WireItem]) {
        let settings = model?.config?.notify ?? NotifySettings()
        let policy = NotifyPolicy(settings: settings)
        let notifiable = policy.notifiable(items)
        guard awayTally.arrived(notifiable.count) else {
            if awayFirstID == nil { awayFirstID = notifiable.first?.id }
            return
        }
        notifier?.handle(newItems: items, settings: settings)
        guard let target = policy.slideInTarget(items), let panel, let store else { return }
        let home = presence.status.state == .home
        if SlideIn.shouldSlide(home: home, slideInOn: settings.slideIn, panelVisible: panel.isShown) {
            panel.slideIn()
            Task { await store.focus(target.id) }
        } else if home, panel.isShown {
            let text = SlideIn.announcement(
                title: target.title, project: target.projectId ?? "",
                outsideFilter: !QueueLayout.matches(target, filter: store.filter))
            NSAccessibility.post(
                element: panel, notification: .announcementRequested,
                userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
        }
    }

    /// New asks count toward the dot only while the panel is hidden (a slide-in shows it right after).
    private func noteArrivals(_ items: [WireItem]) {
        let visible = panel?.isShown ?? false
        updateUnseen { $0.arrived(items.map(\.id), panelVisible: visible) }
    }

    /// Any show of the panel marks every open ask seen.
    private func panelShown() {
        updateUnseen { $0.panelShown() }
    }

    /// Applies a change, saving it and redrawing the badge only when the set moved.
    private func updateUnseen(_ change: (inout UnseenAsks) -> Void) {
        var next = unseen
        change(&next)
        guard next != unseen else { return }
        unseen = next
        next.save(.standard)
        updateMenuBar(refreshingSettings: false)
    }

    /// Removes notifications for asks that left the open list or were reopened. A close
    /// held for Undo or still sending counts as open; its notification goes once the
    /// source confirms the close (onCloseSent).
    private func cleanUpNotifications() {
        guard let store, let notifier else { return }
        let held = lastOpenIDs.intersection(store.heldCloseIDs)
        let open = Set(store.items.map(\.id)).union(held)
        let reopened = open.subtracting(lastOpenIDs).intersection(lastClosedIDs)
        let ids = NotificationCleanup.ids(previousOpen: lastOpenIDs, currentOpen: open, sent: [], reopened: Array(reopened))
        lastOpenIDs = open
        lastClosedIDs = Set(store.recentlyClosed.map(\.id))
        notifier.remove(ids: ids)
    }

    // MARK: Away mode

    /// Quiet or not, the menu bar, and the summary on return home.
    /// Asks that were waiting in the batch window when Relay went away join the count.
    private func presenceChanged(to status: PresenceMonitor.Status) {
        let away = status.state == .away
        // The Store's away flag: the status bar reads "Away · …" with the moon.
        store?.away = away
        let held = notifier?.setQuiet(away) ?? 0
        if let summary = awayTally.changed(to: status.state) {
            notifier?.showReturnSummary(summary, first: awayFirstID, settings: model?.config?.notify ?? NotifySettings())
        }
        if !away { awayFirstID = nil }
        _ = awayTally.arrived(held)
        model?.presenceLine = PresenceLogic.statusLine(
            state: status.state, reason: status.reason, since: ClockText.time(status.since))
        model?.away = away
        updatePresenceMenu()
        updateMenuBar()
    }

    /// The menu reads presence on every open; the status item's tooltip and dimming follow it.
    private func updatePresenceMenu() {
        updateMenuBar()
    }
}

/// The Store values `AppModel.refreshSettings()` reads.
private struct SettingsStoreInputs: Equatable {
    var sourceKey: String
    var reachable: Bool
    var listed: Bool
    var waiting: Int
    var problem: String?

    @MainActor init(_ store: Store) {
        sourceKey = store.sourceKey
        reachable = store.reachable
        listed = store.lastListAt != nil
        waiting = store.items.count
        problem = store.problem
    }
}
