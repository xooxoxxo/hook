import AppKit
import SwiftUI
import RelayCore

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    /// The source the Store currently shows; a swap happens only when it changes.
    private struct AppliedSource: Equatable {
        var key: String
        var mailbox: MailboxSettings?
        var pollSeconds: Int
    }

    private var model: AppModel?
    private var store: Store?
    private var panel: SidePanel?
    private var hotKeys: HotKeyManager?
    private var settings: SettingsWindowController?
    private var welcome: WelcomeWindowController?
    private var notifier: Notifier?
    private var menuBar: MenuBarController?
    /// `showCount` from the applied config.
    private var showCount = true
    private var server: LoopbackServer?
    private var serverPort: Int?
    private let routing = ServerRouting()
    /// Created on first use of the local source and kept for the app's lifetime.
    private var localQueue: LocalQueue?
    private var localAPI: LocalAPI?
    private var localAPIPort: Int?
    /// "Relay is already running", or why the local queue or token isn't available.
    private var localProblem: String?
    private var applied: AppliedSource?
    /// Config applies run one after another (opening the queue is async).
    private var applyChain: Task<Void, Never>?
    private var shownConfigNote: String?
    /// A link that arrived before launch finished.
    private var pendingLink: String?
    /// Quit is waiting on held-back closes; set once the reply has been sent.
    private var terminationAnswered = false
    /// Away mode: the signals, the flag file and the asks counted while away.
    private let presence = PresenceMonitor()
    private var awayTally = AwayTally()
    /// SIGTERM (`kill`, `launchctl bootout`) skips applicationWillTerminate, so it
    /// is caught here to clear the away flag first.
    private var termSource: (any DispatchSourceSignal)?

    func applicationDidFinishLaunching(_ notification: Notification) {
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
        settings = SettingsWindowController(model: model, hotKeys: hotKeys)

        panel = makePanel(store: store, model: model)

        setUpMenuBar()
        store.onStateChange = { [weak self] in self?.updateMenuBar() }
        store.onNewItems = { [weak self] items in
            self?.announce(items)
        }
        let notifier = Notifier { [weak self] id in self?.showItem(id) }
        notifier.onOpenList = { [weak self] in
            self?.store?.select(nil)
            self?.panel?.present(focus: true)
        }
        notifier.requestAuthorization()
        self.notifier = notifier
        settings?.setContent(.queue, SettingsWindowController.hosting(QueueTab(model: model, store: store)))
        settings?.setContent(.notifications, SettingsWindowController.hosting(NotificationsTab(model: model, notifier: notifier)))
        settings?.setContent(.connect, SettingsWindowController.hosting(ConnectTab(model: model)))

        model.onApply = { [weak self] _, new in
            self?.scheduleApply(new)
            self?.applyGeneral(new)
            self?.closeWelcomeIfReady(new)
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

        if let id = pendingLink {
            pendingLink = nil
            openLink(id)
        }
    }

    /// Held-back Done and Skip are sent before quitting, with a 3 s cap so
    /// quitting never hangs on an unreachable source.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let store, store.hasPendingCloses else { return .terminateNow }
        terminationAnswered = false
        Task {
            await store.sendAllPending()
            answerTermination()
        }
        Task {
            try? await Task.sleep(for: .seconds(3))
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
                NSApp.terminate(nil)
            }
        }
        source.resume()
        termSource = source
    }

    private func answerTermination() {
        guard !terminationAnswered else { return }
        terminationAnswered = true
        NSApp.reply(toApplicationShouldTerminate: true)
    }

    /// relay://i/<uuid>
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "relay" && url.host() == "i" {
            if let id = QueueLogic.normalizedID(url.lastPathComponent) {
                openLink(id)
            }
        }
    }

    /// A link from outside the app (relay:// or the loopback server) brings
    /// Relay forward only for an id in the open queue.
    func openLink(_ id: String) {
        guard let store else {
            pendingLink = id
            return
        }
        Task {
            if await store.acceptsLink(id) { showItem(id) }
        }
    }

    func showItem(_ id: String) {
        guard let store, let panel else { return }
        panel.show()
        Task { await store.focus(id) }
    }

    // MARK: Panel

    /// The sidebar panel around RootView. Esc in a detail goes back to the list.
    private func makePanel(store: Store, model: AppModel) -> SidePanel {
        let hosting = NSHostingView(rootView: RootView(store: store, model: model, onSettings: { [weak self] in
            self?.showSettings(nil)
        }))
        hosting.sizingOptions = []
        // No title-bar inset: the content starts at the panel's top edge.
        hosting.safeAreaRegions = []
        let panel = SidePanel(content: hosting)
        panel.connect(model)
        panel.onEscape = { [weak store] in
            guard let store, store.selectedID != nil else { return false }
            store.select(nil)
            return true
        }
        return panel
    }

    /// `sidebarEdge` and `appearance`.
    private func applyPanelSettings(_ config: RelayConfig?) {
        panel?.dock(edge: config?.sidebarEdge ?? .right)
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
                swapIfNeeded(AppliedSource(key: "local", mailbox: nil, pollSeconds: 0)) {
                    LocalQueueSource(queue: queue)
                }
            } else {
                model.localAPI = nil
                routing.update(ServerRouting.Routes(source: "none", api: nil, token: nil))
                swapIfNeeded(AppliedSource(key: "none", mailbox: nil, pollSeconds: 0)) { nil }
            }
        case .mailbox(let settings):
            localProblem = nil
            model.localAPI = nil
            routing.update(ServerRouting.Routes(source: "mailbox", api: nil, token: nil))
            let key = "mailbox:" + (settings.url.host() ?? "")
            swapIfNeeded(AppliedSource(key: key, mailbox: settings, pollSeconds: pollSeconds)) {
                MailboxClient(settings: settings)
            }
        case .incomplete, .invalid:
            localProblem = nil
            model.localAPI = nil
            routing.update(ServerRouting.Routes(source: "none", api: nil, token: nil))
            swapIfNeeded(AppliedSource(key: "none", mailbox: nil, pollSeconds: 0)) { nil }
        }
        restartServerIfNeeded(port: port)
        updateListenerProblem()
        showCount = config?.showCount ?? true
        updateMenuBar()
        applyPanelSettings(config)
    }

    private func swapIfNeeded(_ next: AppliedSource, make: () -> (any QueueSource)?) {
        guard let store, applied != next else { return }
        applied = next
        store.swap(to: make(), sourceKey: next.key, pollSeconds: next.pollSeconds)
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
                showBanner("queue.json couldn't be read, so it was moved to \(moved). A new queue has started.")
            }
            return queue
        } catch LocalQueueError.locked {
            let text = "Relay is already running"
            localProblem = text
            showBanner(text)
        } catch {
            let reason: String
            if case .storeFailed(let text)? = error as? LocalQueueError {
                reason = text
            } else {
                reason = error.localizedDescription
            }
            let text = "Couldn't open the queue: \(reason)"
            localProblem = text
            showBanner(text)
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
            showBanner(text)
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

    /// Local mode: the queue and the listener must both be up.
    private func updateListenerProblem() {
        guard let store, let model else { return }
        guard case .local = model.resolvedSource else {
            store.setListenerProblem(nil)
            return
        }
        if let localProblem {
            store.setListenerProblem(localProblem)
        } else if case .failed(let text) = model.listenerState {
            store.setListenerProblem(text)
        } else {
            store.setListenerProblem(nil)
        }
    }

    // MARK: Banner

    private func showBanner(_ text: String) {
        store?.banner = text
        NSLog("Relay: %@", text)
    }

    /// Mirrors the config note into the banner; clears the banner only if it still shows the old note.
    private func configNoteChanged(_ note: String?) {
        guard let store else { return }
        if let note {
            showBanner(note)
        } else if store.banner != nil, store.banner == shownConfigNote {
            store.banner = nil
        }
        shownConfigNote = note
    }

    // MARK: Menu bar

    private func setUpMenuBar() {
        menuBar = MenuBarController(
            onToggle: { [weak self] in self?.togglePanel() },
            onRefresh: { [weak self] in self?.refreshNow() },
            onSettings: { [weak self] in self?.showSettings(nil) },
            onPresence: { [weak self] mode in self?.model?.save(set: ["presence": mode.rawValue]) },
            onQuit: { NSApp.terminate(nil) })
        MainMenu.install(settings: #selector(showSettings(_:)), refresh: #selector(refreshNow), target: self)
        updateMenuBar()
        updateShortcutLabel()
    }

    /// Count, "now" dot, dimming and tooltip, after every Store change.
    private func updateMenuBar() {
        guard let store else { return }
        menuBar?.update(store.menuBarState(showCount: showCount, away: presence.status.state == .away))
    }

    /// "Shortcut: ⌃⌥⌘R", or "Shortcut: (not set)" when off or not registered.
    /// Also mirrored into the model for the sidebar footer's hint.
    private func updateShortcutLabel() {
        let label = hotKeys?.label ?? HotKeyManager.offLabel
        menuBar?.setShortcutLabel("Shortcut: " + label)
        model?.setShortcutLabel(label == HotKeyManager.offLabel ? nil : label)
    }

    /// Settings… from ⌘,, the status-item menu and the sidebar footer.
    @objc func showSettings(_ sender: Any?) {
        settings?.show()
    }

    /// First launch with no usable config.
    private func showWelcome() {
        guard let model else { return }
        let welcome = self.welcome ?? WelcomeWindowController(model: model)
        self.welcome = welcome
        welcome.show()
    }

    /// Welcome closes itself once a config resolves to a source: after Start, or
    /// when install.sh writes config.json while it's open. The controller is kept,
    /// because Start's button action may still be running when this is called.
    private func closeWelcomeIfReady(_ config: RelayConfig?) {
        guard let welcome, let config else { return }
        switch config.resolvedSource() {
        case .local, .mailbox:
            welcome.close()
        case .incomplete, .invalid:
            break
        }
    }

    // MARK: Global shortcut

    /// The General setting nothing else applies: the global shortcut.
    /// Runs at launch and on every config change; a hotkey the General tab just
    /// registered is the same spec, so `apply` is a no-op then. `appearance`,
    /// `sidebarEdge` and `showCount` are applied at the end of `apply(_:)`.
    private func applyGeneral(_ config: RelayConfig?) {
        presence.configure(
            mode: config?.presence ?? .auto,
            awayAfterMinutes: config?.awayAfterMinutes ?? PresenceLogic.defaultAwayAfterMinutes)
        updatePresenceMenu()
        guard let hotKeys else { return }
        // A later successful apply clears an earlier failure's red line.
        model?.hotkeyStatus = hotKeys.apply(config?.hotkey ?? HotkeySpec.defaultString) ? nil : GeneralTab.shortcutFailed
        updateShortcutLabel()
    }

    @objc private func togglePanel() {
        panel?.toggle()
    }

    @objc private func refreshNow() {
        guard let store else { return }
        Task { await store.refresh() }
    }

    // MARK: Notifications

    /// New asks from the Store diff. A new "now" ask also slides the
    /// sidebar in on that ask without taking focus, unless the sidebar is already up.
    /// While away, the asks are only counted, and only those whose urgency is
    /// switched on in Notifications, so the summary covers what would have notified.
    private func announce(_ items: [WireItem]) {
        let settings = model?.config?.notify ?? NotifySettings()
        guard awayTally.arrived(NotifyPolicy(settings: settings).notifiable(items).count) else { return }
        notifier?.handle(newItems: items, settings: settings)
        guard let target = NotifyPolicy(settings: settings).slideInTarget(items),
              let panel, let store, !panel.isVisible else { return }
        panel.present(focus: false)
        Task { await store.focus(target.id) }
    }

    // MARK: Away mode

    /// Quiet or not, the menu bar, and the summary on return home.
    /// Asks that were waiting in the batch window when Relay went away join the count.
    private func presenceChanged(to status: PresenceMonitor.Status) {
        let away = status.state == .away
        let held = notifier?.setQuiet(away) ?? 0
        if let summary = awayTally.changed(to: status.state) {
            notifier?.showReturnSummary(summary, settings: model?.config?.notify ?? NotifySettings())
        }
        _ = awayTally.arrived(held)
        updatePresenceMenu()
        updateMenuBar()
    }

    private func updatePresenceMenu() {
        let status = presence.status
        let since = status.since.formatted(date: .omitted, time: .shortened)
        menuBar?.setPresence(
            line: PresenceLogic.statusLine(state: status.state, reason: status.reason, since: since),
            mode: presence.mode)
    }
}
