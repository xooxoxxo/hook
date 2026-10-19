import Foundation
import RelayCore

/// The app's state over one `QueueSource` at a time: the open queue, fetched
/// details, the selection, and the owner's actions. Lives in RelayUI so the
/// gallery and tests can drive it; views reach it through PanelViewModel (Task 39).
@MainActor public final class Store: ObservableObject {
    /// The open queue as shown: the source's list without the asks held back
    /// for Undo or being sent. Every list, count and badge reads this.
    @Published public private(set) var items: [WireItem] = []
    /// Done and Skip held back for `PendingCloses.delay` seconds so they can be undone.
    @Published public private(set) var pending = PendingCloses()
    /// Asks closed in the last 24 hours, newest first, without any still held back.
    @Published public private(set) var recentlyClosed: [WireItem] = []
    @Published public private(set) var details: [String: AskDetail] = [:]
    /// The highlighted row and the open detail (design §4.6).
    @Published public var navigation = PanelNavigation()
    /// Unsent reply text per ask. Memory only: the owner's text is never written to disk unasked.
    @Published public var drafts: [String: String] = [:]
    /// The picked, unsent choice index per ask. Memory only.
    @Published public var pendingChoice: [String: Int] = [:]
    @Published public private(set) var replyStates: [String: ReplyBoxState] = [:]
    /// How long "Sent 10:42" stays in the reply box; tests pass a short one.
    let sentHold: Duration
    /// The wait behind `sentHold`; tests pass one they release by hand.
    let sleep: @Sendable (Duration) async throws -> Void
    /// The running "Sent" reset per ask. A new send cancels the old one, so an
    /// earlier timer never clears a later send's caption.
    private var sentResets: [String: (token: UUID, task: Task<Void, Never>)] = [:]
    /// The real wait. A nonisolated function, not a closure literal in the init's
    /// default argument: that literal aborted the Swift 6.2 runtime ("freed pointer
    /// was not the last allocation") when the sleep finished.
    nonisolated static func taskSleep(_ duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }
    /// After Done or Skip in the detail; AppDelegate sets it from config.json.
    public var afterClose: AfterClose = .next
    /// One Notice at a time; the newest replaces the older; only ✕ or its action clears it.
    @Published public private(set) var notice: PanelNotice?
    /// A close was sent or an ask reopened: remove its delivered notification (Task 58).
    public var onCloseSent: (@MainActor (String) -> Void)?
    /// Text for VoiceOver to announce ("Ask reopened").
    public var onAnnounce: (@MainActor (String) -> Void)?
    /// The queueMoved Notice's "Show in Finder".
    public var onShowInFinder: (@MainActor (String) -> Void)?
    /// Closes whose send failed, by id, for the Notice's Retry.
    private var failedCloses: [String: PendingClose] = [:]
    /// The ask that was open when the source swapped; checked against the first list.
    private var reloadCheckID: String?
    /// The offline Notice was posted in this outage; reset by a good list or a swap.
    private var offlineNoticed = false
    /// The ask after the one the session closed, taken from the order before it left the list.
    private var sessionClosedNext: String?
    /// Done steps the owner expanded, by ask; node paths. Memory only, on purpose.
    @Published public var expandedDone: [String: Set<String>] = [:]
    /// The path of the top visible node per ask, for the detail's scroll position. Memory only.
    @Published public var detailAnchor: [String: String] = [:]
    /// Tick paths as loaded from TickStore, per ask, with the step source they were loaded
    /// against; dropped when the ask's detail changes, and reloaded when the source differs.
    /// Keyed on the source, not the tree: comparing it is cheap, building the tree hashes every step.
    private var tickCache: [String: (source: StepSource, ticks: Set<String>)] = [:]
    /// How many times a step tree was built; tests check the tick cache saves this work.
    private(set) var stepTreeBuilds = 0
    /// Leaves ticked this session, in order, per ask (for ⇧⌘T).
    private var tickHistory: [String: [String]] = [:]
    /// Set by AppDelegate: the config note, presence and quit-time sends, for the status bar.
    @Published public var configNote: String?
    /// config.json's problem, from AppModel; the status bar shows it ("config.json has an error").
    /// Assigning only on change keeps a reload with the same problem from republishing.
    public func setConfigNote(_ note: String?) {
        guard configNote != note else { return }
        configNote = note
    }
    @Published public var away = false
    @Published public var sendingCloses = 0
    /// The Undo bar as it was when the quit-time sends began; `undoInfo` while they run.
    @Published private var sendingUndo: UndoInfo?
    public var shell = PanelShellActions.none
    private var detailRequestedAt: [String: Date] = [:]
    private var detailFailed: Set<String> = []
    private var swappedAt: Date?
    /// Bumped when a load has waited `DetailLoadState.timeout`, so views read the
    /// snapshots again and "Still trying…" / "Couldn't load" show with no other change (N9).
    @Published public private(set) var stateTick = 0
    /// The wait behind `stateTick`; tests pass an immediate one.
    let timeoutSleep: @Sendable (Duration) async -> Void
    /// The pending timeout waits, by token; a swap cancels them all.
    private var stateTimers: [UUID: Task<Void, Never>] = [:]
    /// The real timeout wait, a nonisolated function for the same reason as `taskSleep`.
    nonisolated static func timeoutTaskSleep(_ duration: Duration) async {
        try? await Task.sleep(for: duration)
    }
    @Published public private(set) var grouping: QueueGrouping
    /// The raw project string; nil = All Projects.
    @Published public private(set) var filter: String?
    @Published public private(set) var manualRefreshing = false
    /// When the last list came back.
    public private(set) var lastListAt: Date?
    @Published public private(set) var notFoundID: String?
    /// The last list succeeded and the listener has no problem.
    @Published public private(set) var reachable = false
    /// Why the source is offline; shown in the footer and the menu-bar tooltip.
    @Published public private(set) var problem: String?
    @Published public private(set) var refreshing = false
    /// "none", "local" or "mailbox:<host>"; ticks and the Connect tab key on it.
    @Published public private(set) var sourceKey = SourceKey.none

    /// Items that appeared since the previous list (never on the first list after launch or a swap).
    public var onNewItems: (@MainActor ([WireItem]) -> Void)?
    /// After items or reachability change; AppDelegate recomputes the menu bar.
    public var onStateChange: (@MainActor () -> Void)?

    public static let noSourceProblem = "No queue is set up"

    private var source: (any QueueSource)?
    private var pollSeconds = RelayConfig.defaultPollSeconds
    /// Bumped by every swap; results started under an older value are dropped.
    var generation = 0
    private var watchTask: Task<Void, Never>?
    var loadedOnce = false
    private var inFlight: Task<Void, Never>?
    /// Bumped by every refresh that starts a list; only the latest one clears `inFlight`.
    private var refreshCount = 0
    private var lastLinkRefresh: ContinuousClock.Instant?
    var listOK = false
    var listProblem: String? = Store.noSourceProblem
    var listenerProblem: String?
    /// The source's open list, pending asks included.
    var listed: [WireItem] = []
    /// Closes taken off `pending` whose send hasn't finished (or whose list hasn't caught up).
    private var sending: Set<String> = []
    private var ticker: Task<Void, Never>?
    /// "id completedAt" → the closing event's actor, so each close is fetched once.
    private var closedActors: [String: String] = [:]
    /// Reopened asks: their return to the list is not a new ask to announce.
    private var quietIDs: Set<String> = []

    public static let closedWindow: TimeInterval = 24 * 3600

    let defaults: UserDefaults
    /// The clock for held closes and staleness; tests pass their own.
    let now: @MainActor () -> Date
    /// What the Store shows now; a different identity swaps the source.
    @Published public private(set) var identity = SourceIdentity(key: SourceKey.none, mailbox: nil)
    /// The source has no change stream, so a timer lists every pollSeconds.
    private var polling = false

    public init(defaults: UserDefaults = .standard, now: @escaping @MainActor () -> Date = { Date() },
                sentHold: Duration = .seconds(4),
                sleep: (@Sendable (Duration) async throws -> Void)? = nil,
                timeoutSleep: (@Sendable (Duration) async -> Void)? = nil) {
        self.defaults = defaults
        self.now = now
        self.sentHold = sentHold
        self.sleep = sleep ?? Store.taskSleep
        self.timeoutSleep = timeoutSleep ?? Store.timeoutTaskSleep
        self.grouping = PanelPrefs.grouping(defaults)
    }

    /// Swap: 1 bump the generation; 2 stop the poll or stream; 3 clear the
    /// details, items and not-found, and restore the source's saved selection and
    /// filter (the open detail closes); 4 the next first load never
    /// notifies; 5 subscribe or poll, and refresh.
    public func swap(to source: (any QueueSource)?, identity: SourceIdentity, pollSeconds: Int) {
        let openID = navigation.selectedID
        // Closes still held back belong to the old source: send them now.
        flushAll(to: self.source)
        generation += 1
        watchTask?.cancel()
        watchTask = nil
        inFlight = nil
        refreshing = false

        navigation = PanelNavigation(listSelection: PanelPrefs.selection(defaults, sourceKey: identity.key), selectedID: openID)
        reloadCheckID = openID
        failedCloses = [:]
        notice = nil
        offlineNoticed = false
        sessionClosedNext = nil
        filter = PanelPrefs.filter(defaults, sourceKey: identity.key)
        lastListAt = nil
        details = [:]
        tickCache = [:]
        tickHistory = [:]
        expandedDone = [:]
        detailAnchor = [:]
        replyStates = [:]
        sentResets.values.forEach { $0.task.cancel() }
        sentResets = [:]
        listed = []
        items = []
        sending = []
        recentlyClosed = []
        closedActors = [:]
        quietIDs = []
        swappedAt = now()
        detailRequestedAt = [:]
        detailFailed = []
        stateTimers.values.forEach { $0.cancel() }
        stateTimers = [:]
        notFoundID = nil

        loadedOnce = false
        polling = false
        self.source = source
        self.identity = identity
        self.sourceKey = identity.key
        self.pollSeconds = max(1, pollSeconds)
        listOK = false
        listProblem = source == nil ? Self.noSourceProblem : nil
        publishState()

        // No source means no first list to check the open ask against: it closes now.
        if source == nil, openID != nil {
            reloadCheckID = nil
            navigation.back()
            post(.settingsReloaded)
        }
        guard let source else { return }
        scheduleTimeoutTick()
        watchTask = watch(source)
    }

    /// One wait of `DetailLoadState.timeout`, then a `stateTick` bump. The next swap cancels it.
    private func scheduleTimeoutTick() {
        let token = UUID(), sleep = timeoutSleep
        stateTimers[token] = Task { [weak self] in
            await sleep(.seconds(DetailLoadState.timeout))
            guard !Task.isCancelled, let self, self.stateTimers.removeValue(forKey: token) != nil else { return }
            self.stateTick += 1
        }
    }

    /// A new interval restarts only the timer: no swap, so the selection, items,
    /// details and held closes stay (M13). A source with a change stream ignores it.
    public func setPollInterval(_ seconds: Int) {
        let seconds = max(1, seconds)
        guard seconds != pollSeconds else { return }
        pollSeconds = seconds
        guard polling, source != nil else { return }
        watchTask?.cancel()
        watchTask = pollTask(every: seconds, refreshFirst: false)
    }

    private func watch(_ source: any QueueSource) -> Task<Void, Never> {
        Task { [weak self] in
            if let stream = await source.changes() {
                await self?.refresh()
                for await _ in stream {
                    guard !Task.isCancelled, let self else { return }
                    await self.refresh()
                }
            } else {
                guard !Task.isCancelled, let self else { return }
                self.polling = true
                // Read the interval now, not when watch started: a setPollInterval that ran
                // while `changes()` was pending only stored it (polling was still false).
                self.watchTask = self.pollTask(every: self.pollSeconds, refreshFirst: true)
            }
        }
    }

    private func pollTask(every seconds: Int, refreshFirst: Bool) -> Task<Void, Never> {
        Task { [weak self] in
            var wait = !refreshFirst
            while !Task.isCancelled {
                if wait { try? await Task.sleep(for: .seconds(seconds)) }
                wait = true
                guard !Task.isCancelled, let self else { return }
                await self.refresh()
            }
        }
    }

    /// Local mode: a listener problem ("Port … is in use by another app",
    /// "Relay is already running") makes the source unreachable with that reason.
    public func setListenerProblem(_ text: String?) {
        guard listenerProblem != text else { return }
        listenerProblem = text
        publishState()
    }

    /// One list of the queue. A call made while one runs waits for that one.
    /// The list task clears `inFlight` itself as it ends: a caller that joined it may
    /// resume first, and its next refresh must list again, not join the finished one.
    public func refresh() async {
        if let inFlight { return await inFlight.value }
        refreshCount += 1
        let token = refreshCount
        let task = Task {
            await self.poll()
            if self.refreshCount == token {
                self.inFlight = nil
                self.refreshing = false
            }
        }
        inFlight = task
        refreshing = true
        await task.value
    }

    /// Whether a link from outside the app (loopback or relay://) may open `id`:
    /// it must be in the open queue, after at most one refresh per 5 seconds.
    public func acceptsLink(_ id: String) async -> Bool {
        if items.contains(where: { $0.id == id }) { return true }
        if hidden.contains(id) { return false }
        let now = ContinuousClock.now
        if let last = lastLinkRefresh, now - last < .seconds(5) { return false }
        lastLinkRefresh = now
        await refresh()
        return items.contains { $0.id == id }
    }

    private func poll() async {
        let gen = generation
        guard let source else {
            listOK = false
            listProblem = Self.noSourceProblem
            publishState()
            return
        }
        do {
            let fresh = try await source.list()
            guard gen == generation else { return }
            let diff = QueueLogic.diff(old: listed, new: fresh)
            listed = fresh
            if let id = reloadCheckID {
                reloadCheckID = nil
                if !fresh.contains(where: { $0.id == id }) {
                    navigation.back()
                    post(.settingsReloaded)
                }
            }
            if let selected = navigation.selectedID, diff.removed.contains(selected),
               !pending.contains(selected), !sending.contains(selected) {
                // visibleOrder still holds the closed ask here: updateItems() hasn't run yet.
                sessionClosedNext = Flow.nextAsk(after: selected, in: visibleOrder)
                post(.sessionClosed(id: selected))
            }
            updateItems()
            listOK = true
            listProblem = nil
            offlineNoticed = false
            if showsOfflineNotice { notice = nil }
            lastListAt = now()
            for id in diff.removed where id != navigation.selectedID {
                details[id] = nil
            }
            publishState()
            var toLoad = diff.added + diff.changed
            if let selected = navigation.selectedID, !toLoad.contains(selected) {
                toLoad.append(selected)
            }
            for id in toLoad {
                await load(id, from: source, generation: gen)
            }
            guard gen == generation else { return }
            let announce = diff.added.filter { !quietIDs.contains($0) }
            quietIDs.subtract(diff.added)
            if loadedOnce, !announce.isEmpty {
                onNewItems?(items.filter { announce.contains($0.id) })
            }
            await loadClosed(from: source, generation: gen)
            guard gen == generation else { return }
            loadedOnce = true
            pruneTicks()
        } catch {
            guard gen == generation else { return }
            listOK = false
            listProblem = error.localizedDescription
            // Once per outage: repeated failed polls don't re-post it.
            if loadedOnce, !offlineNoticed {
                offlineNoticed = true
                post(.offlineCached(since: ClockText.time(lastListAt ?? now())))
            }
            publishState()
        }
    }

    public func open(_ id: String) {
        let listed = visibleOrder.contains(id) || closedShown.contains { $0.id == id }
        navigation.open(id, listed: listed)
        saveSelection()
        notFoundID = nil
        if details[id] == nil {
            detailRequestedAt[id] = now()
            scheduleTimeoutTick()
        }
        loadIfMissing(id)
    }

    public func back() {
        navigation.back()
        notFoundID = nil
    }

    func loadIfMissing(_ id: String) {
        guard details[id] == nil, let source else { return }
        let gen = generation
        Task { await self.load(id, from: source, generation: gen) }
    }

    public var listSelection: String? {
        get { navigation.listSelection }
        set {
            navigation.listSelection = newValue
            saveSelection()
        }
    }

    private func saveSelection() {
        PanelPrefs.setSelection(navigation.listSelection, defaults, sourceKey: sourceKey)
    }

    public func settleSelection() {
        navigation.settle(visibleOrder: visibleOrder, closedOrder: closedShown.map(\.id))
        saveSelection()
    }

    public func setGrouping(_ grouping: QueueGrouping) {
        self.grouping = grouping
        PanelPrefs.setGrouping(grouping, defaults)
    }

    public func setFilter(_ project: String?) {
        filter = project
        PanelPrefs.setFilter(project, defaults, sourceKey: sourceKey)
        navigation.filterChanged(visibleOrder: visibleOrder, closedOrder: closedShown.map(\.id))
        saveSelection()
    }

    public var sections: [QueueSection] { QueueLayout.sections(items: items, grouping: grouping, filter: filter) }
    public var visibleOrder: [String] { QueueLayout.visibleOrder(sections) }
    public var closedShown: [WireItem] { QueueLayout.closed(recentlyClosed, filter: filter) }
    public var hiddenCount: HiddenCount { QueueLayout.hiddenCount(items: items, filter: filter) }
    public var menuProjects: [MenuProject] { QueueLayout.menuProjects(items: items, filter: filter) }

    /// The header spinner shows only for this one; background polls change nothing there.
    public func refresh(manual: Bool) async {
        if manual { manualRefreshing = true }
        await refresh()
        if manual { manualRefreshing = false }
    }

    /// How old the last list may be before showing the panel in mailbox mode lists again.
    public static let staleAfter: TimeInterval = 5

    /// Showing the panel in mailbox mode lists again when the last list is older than `staleAfter`.
    public func refreshIfStale() async {
        guard sourceKey.hasPrefix("mailbox:") else { return }
        if let last = lastListAt, now().timeIntervalSince(last) <= Self.staleAfter { return }
        await refresh()
    }

    /// Deep link target: select the item, fetch it, and fall back to a refresh
    /// and then "not found" when the source does not know the id.
    public func focus(_ id: String) async {
        open(id)
        guard let source else {
            notFoundID = id
            return
        }
        let gen = generation
        do {
            let detail = try await source.get(id)
            guard gen == generation else { return }
            details[id] = detail
            tickCache[id] = nil
        } catch QueueError.notFound {
            guard gen == generation else { return }
            await refresh()
            guard gen == generation else { return }
            if details[id] == nil, !listed.contains(where: { $0.id == id }) {
                notFoundID = id
            }
        } catch {
            guard gen == generation else { return }
            listOK = false
            listProblem = error.localizedDescription
            publishState()
        }
    }

    public func item(for id: String) -> WireItem? {
        details[id]?.item ?? listed.first { $0.id == id } ?? recentlyClosed.first { $0.id == id }
    }

    public func detail(for id: String) -> AskDetail? {
        details[id]
    }

    /// The ask's step tree: from the fetched detail's item, else from the list item.
    /// Only the item shapes the nodes (events never do), so both give the same tree.
    func nodes(for id: String) -> [DetailModel.Node]? {
        guard let item = item(for: id) else { return nil }
        return stepTree(item)
    }

    private func stepTree(_ item: WireItem) -> [DetailModel.Node] {
        stepTreeBuilds += 1
        return DetailModel.make(item: item, events: []).nodes
    }

    /// The ticked leaves of the ask's current tree whose fingerprint matches; a tick
    /// for a removed or edited step is dropped, so no count ever includes it.
    /// Cheap on a hit: rows call this on every render, so the tree is built only on a miss.
    public func ticks(for id: String) -> Set<String> {
        guard let item = item(for: id) else { return [] }
        let source = StepSource(item)
        if let cached = tickCache[id], cached.source == source { return cached.ticks }
        let loaded = TickStore.load(defaults, sourceKey: sourceKey, id: id, nodes: stepTree(item))
        tickCache[id] = (source, loaded)
        return loaded
    }

    /// A leaf flips; a parent ticks or unticks all its sub-steps (Flow.toggle). Saves.
    public func toggleTick(_ path: String, in id: String) {
        guard let nodes = nodes(for: id), let node = Flow.flattened(nodes).first(where: { $0.path == path }) else { return }
        let before = ticks(for: id)
        let after = Flow.toggle(node, ticks: before)
        let added = Flow.leaves(of: nodes).map(\.path).filter { after.contains($0) && !before.contains($0) }
        tickHistory[id, default: []].append(contentsOf: added)
        setTicks(after, for: id, nodes: nodes)
    }

    /// ⌘T: ticks the current leaf and returns its path; nil when every leaf is ticked.
    @discardableResult public func tickCurrent(in id: String) -> String? {
        guard let nodes = nodes(for: id) else { return nil }
        let result = Flow.tickCurrent(ticks: ticks(for: id), nodes: nodes)
        guard let path = result.path else { return nil }
        tickHistory[id, default: []].append(path)
        setTicks(result.ticks, for: id, nodes: nodes)
        return path
    }

    /// ⇧⌘T: unticks the leaf ticked last this session, else the last ticked leaf in order.
    @discardableResult public func untickLast(in id: String) -> String? {
        guard let nodes = nodes(for: id) else { return nil }
        let result = Flow.untickLast(ticks: ticks(for: id), history: tickHistory[id] ?? [], nodes: nodes)
        guard let path = result.path else { return nil }
        tickHistory[id]?.removeAll { $0 == path }
        setTicks(result.ticks, for: id, nodes: nodes)
        return path
    }

    private func setTicks(_ ticks: Set<String>, for id: String, nodes: [DetailModel.Node]) {
        objectWillChange.send()
        let leaves = ticks.intersection(Flow.leaves(of: nodes).map(\.path))
        tickCache[id] = item(for: id).map { (StepSource($0), leaves) }
        TickStore.save(defaults, sourceKey: sourceKey, id: id, ticks: leaves, nodes: nodes)
    }

    /// After a good list of this source: keeps ticks of open asks (held ones are still
    /// listed), of Recently closed and of the open detail, whatever the filter.
    func pruneTicks() {
        guard reachable, !listed.isEmpty else { return }
        var keep = Set(listed.map(\.id)).union(recentlyClosed.map(\.id)).union(sending)
        if let selected = navigation.selectedID { keep.insert(selected) }
        TickStore.prune(defaults, sourceKey: sourceKey, keep: keep)
    }

    /// Done or Skip, held 10 s for Undo. In the detail, `afterClose` decides whether
    /// the next ask opens; from the list, the next row is selected.
    public func close(_ id: String, _ verdict: Verdict) {
        guard source != nil else { return }
        let order = visibleOrder
        let inDetail = navigation.selectedID == id
        pending.add(id: id, verdict: verdict, note: nil, title: item(for: id)?.title ?? "", now: now())
        onAnnounce?(UndoBar.announcement(for: verdict))
        recentlyClosed.removeAll { $0.id == id }
        if inDetail { notFoundID = nil }
        navigation.afterClose(id, visibleOrder: order, setting: afterClose, inDetail: inDetail)
        saveSelection()
        if let next = navigation.selectedID { loadIfMissing(next) }
        updateItems()
        publishState()
        startTicker()
    }

    /// Restores the latest held close; called again, the one before.
    public func undo() {
        guard let restored = pending.undoLatest() else { return }
        updateItems()
        publishState()
        navigation.undoRestored(restored.id, visibleOrder: visibleOrder)
        saveSelection()
    }

    public var undoInfo: UndoInfo? {
        if let sendingUndo { return sendingUndo }
        guard let latest = pending.latest else { return nil }
        return UndoInfo(verdict: latest.verdict, title: latest.title, deadline: latest.deadline, more: pending.count - 1)
    }

    public func post(_ notice: PanelNotice) { self.notice = notice }

    public func dismissNotice() { notice = nil }

    /// The Notice's button: Retry, Next Ask, Show Closed Ask, Try Again or Show in Finder.
    public func performNoticeAction() async {
        guard let current = notice else { return }
        notice = nil
        switch current {
        case .actionFailed(_, let id, _, _):
            guard let close = failedCloses.removeValue(forKey: id), let source else { return }
            sending.insert(id)
            updateItems()
            publishState()
            await send(close, via: source, generation: generation)
        case .reopenFailed(let id, _, _):
            await reopen(id)
        case .sessionClosed:
            if let next = sessionClosedNext, visibleOrder.contains(next) {
                open(next)
            } else if let first = visibleOrder.first {
                open(first)
            } else {
                back()
            }
            sessionClosedNext = nil
        case .noLongerOpen(let id, let canShowClosed):
            if canShowClosed { open(id) }
        case .offlineCached:
            await refresh(manual: true)
        case .queueMoved(let path):
            onShowInFinder?(path)
        case .storeFailed, .settingsReloaded:
            break
        }
    }

    private var showsOfflineNotice: Bool {
        if case .offlineCached? = notice { return true }
        return false
    }

    /// Before quitting: sends every held-back close at once. The caller caps the wait.
    /// The Undo bar shown while they go (ruling 2: "Sending", Undo disabled) is the one from
    /// before the drain, kept in `sendingUndo` until every send has finished.
    public func sendAllPending() async {
        guard let source else { return }
        let shown = undoInfo
        let all = pending.drainAll()
        guard !all.isEmpty else { return }
        sendingUndo = shown
        publishState()
        await withTaskGroup(of: Void.self) { group in
            for close in all {
                group.addTask {
                    _ = try? await source.resolve(close.id, verdict: close.verdict, note: close.note)
                }
            }
        }
        sendingUndo = nil
        publishState()
    }

    public var hasPendingCloses: Bool { !pending.isEmpty }

    /// The actor of the event that closed `item` ("owner", "session"), once fetched.
    public func closedBy(_ item: WireItem) -> String? {
        closedActors[Self.closedKey(item)]
    }

    /// Puts a closed ask back in the open queue, as the owner.
    public func reopen(_ id: String) async {
        guard let source else { return }
        let gen = generation
        do {
            _ = try await source.reopen(id)
            guard gen == generation else { return }
            quietIDs.insert(id)
            recentlyClosed.removeAll { $0.id == id }
            await freshRefresh()
            guard gen == generation else { return }
            if navigation.selectedID == id { await load(id, from: source, generation: gen) }
            onCloseSent?(id)
            onAnnounce?("Ask reopened")
        } catch {
            guard gen == generation else { return }
            post(.reopenFailed(id: id, title: item(for: id)?.title ?? "", reason: UserFacingError.text(error)))
        }
    }

    /// The last 24 hours of closed asks, and who closed each (from its events).
    /// A failed fetch keeps the previous list.
    private func loadClosed(from source: any QueueSource, generation gen: Int) async {
        guard let fresh = try? await source.recentlyClosed(within: Self.closedWindow) else { return }
        guard gen == generation else { return }
        let open = Set(listed.map(\.id))
        let closed = fresh.filter { !open.contains($0.id) && !pending.contains($0.id) }
        var actors: [String: String] = [:]
        for item in closed {
            let key = Self.closedKey(item)
            if let known = closedActors[key] {
                actors[key] = known
            } else if let detail = try? await source.get(item.id),
                      let actor = DetailModel.make(detail).closedBy {
                guard gen == generation else { return }
                actors[key] = actor
            }
        }
        guard gen == generation else { return }
        closedActors = actors
        if closed != recentlyClosed { recentlyClosed = closed }
    }

    private static func closedKey(_ item: WireItem) -> String {
        item.id + " " + (item.completedAt ?? "")
    }

    /// Every id the open list was refreshed with, pending ones included (for tick pruning).
    public var listedIDs: Set<String> { Set(listed.map(\.id)) }

    private var hidden: Set<String> {
        var ids = sending
        if !pending.isEmpty {
            for item in listed where pending.contains(item.id) { ids.insert(item.id) }
        }
        return ids
    }

    private func updateItems() {
        let hidden = self.hidden
        let shown = hidden.isEmpty ? listed : listed.filter { !hidden.contains($0.id) }
        if shown != items { items = shown }
    }

    /// About once a second while anything is held back: sends what is due.
    private func startTicker() {
        guard ticker == nil else { return }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                if self.sendDue() {
                    self.ticker = nil
                    return
                }
            }
        }
    }

    /// Returns true once nothing is held back. Internal so tests can run it after moving the clock.
    @discardableResult func sendDue() -> Bool {
        let due = pending.due(now: now())
        if let source {
            let gen = generation
            for close in due {
                sending.insert(close.id)
                Task { await self.send(close, via: source, generation: gen) }
            }
        }
        if !due.isEmpty {
            updateItems()
            publishState()
        }
        return pending.isEmpty
    }

    /// The resolve itself. The ask stays hidden until a list that started after
    /// the send has come back; on failure it reappears and a Notice says why.
    private func send(_ close: PendingClose, via source: any QueueSource, generation gen: Int) async {
        do {
            _ = try await source.resolve(close.id, verdict: close.verdict, note: close.note)
            guard gen == generation else { return }
            details[close.id] = nil
            await freshRefresh()
            guard gen == generation else { return }
            sending.remove(close.id)
            failedCloses[close.id] = nil
            onCloseSent?(close.id)
            updateItems()
        } catch {
            guard gen == generation else { return }
            sending.remove(close.id)
            updateItems()
            publishState()
            failedCloses[close.id] = close
            post(.actionFailed(verdict: close.verdict, id: close.id, title: close.title, reason: UserFacingError.text(error)))
        }
    }

    /// A refresh that starts after this call: waits out one already running.
    private func freshRefresh() async {
        if let inFlight { await inFlight.value }
        await refresh()
    }

    /// A swap: whatever is still held back goes to the old source straight away.
    private func flushAll(to old: (any QueueSource)?) {
        ticker?.cancel()
        ticker = nil
        let all = pending.drainAll()
        guard let old, !all.isEmpty else { return }
        Task.detached {
            for close in all {
                do {
                    _ = try await old.resolve(close.id, verdict: close.verdict, note: close.note)
                } catch {
                    NSLog("Relay: a held-back close couldn't be sent before the queue changed: %@",
                          error.localizedDescription)
                }
            }
        }
    }

    /// Sends one reply event and reloads the ask, so its events (and sent choices) update.
    /// A send that finishes after a swap comes back as a CancellationError and changes nothing.
    private func deliver(_ id: String, text: String) async -> Result<Void, any Error> {
        guard let source else { return .failure(QueueError.unreachable(Self.noSourceProblem)) }
        let gen = generation
        do {
            _ = try await source.reply(id, text: text)
            guard gen == generation else { return .failure(CancellationError()) }
            await load(id, from: source, generation: gen)
            return .success(())
        } catch {
            guard gen == generation else { return .failure(CancellationError()) }
            return .failure(error)
        }
    }

    public func sendReply(_ id: String) async -> Bool {
        let text = (drafts[id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, replyStates[id] != .sending else { return false }
        return await send(text, for: id) { self.drafts[id] = nil }
    }

    public func sendChoice(_ id: String) async -> Bool {
        guard let index = pendingChoice[id], let choices = item(for: id)?.instructable?.reply?.choices,
              choices.indices.contains(index), replyStates[id] != .sending else { return false }
        return await send(ReplyText.wire(choice: choices[index]), for: id) { self.pendingChoice[id] = nil }
    }

    /// ⌘↩ / the primary button: Done, or send first and close only when the send worked.
    public func sendAndDone(_ id: String) async {
        guard primaryAction(for: id) == .sendAndDone else {
            close(id, .done)
            return
        }
        let hasText = !(drafts[id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let sent = hasText ? await sendReply(id) : await sendChoice(id)
        if sent { close(id, .done) }
    }

    private func send(_ text: String, for id: String, onSuccess: () -> Void) async -> Bool {
        sentResets.removeValue(forKey: id)?.task.cancel()
        replyStates[id] = .sending
        let gen = generation
        let result = await deliver(id, text: text)
        // A swap while the send was out cleared this ask's state; the old source's answer writes nothing.
        guard gen == generation else { return false }
        switch result {
        case .success:
            onSuccess()
            replyStates[id] = .sent(at: ClockText.time(now()))
            let hold = sentHold, sleep = sleep, token = UUID()
            let reset = Task { [weak self] in
                try? await sleep(hold)
                // Only the newest send's timer may clear the caption.
                guard !Task.isCancelled, let self, self.sentResets[id]?.token == token else { return }
                self.sentResets[id] = nil
                if case .sent = self.replyStates[id] { self.replyStates[id] = .idle }
            }
            sentResets[id] = (token, reset)
            return true
        case .failure(let error):
            replyStates[id] = .failed(reason: UserFacingError.text(error))
            return false
        }
    }

    public func primaryAction(for id: String) -> PrimaryAction {
        Flow.primaryAction(draft: drafts[id], choice: pendingChoice[id], sent: latestSentChoice(for: id))
    }

    public func replyLines(for id: String) -> [ReplyLine] {
        ReplyText.lines(events: details[id]?.events ?? [])
    }

    public func latestSentChoice(for id: String) -> Int? {
        guard let choices = item(for: id)?.instructable?.reply?.choices else { return nil }
        return ReplyText.latestSentChoice(events: details[id]?.events ?? [], choices: choices)
    }

    /// Posts through the current source (Settings' "Send a test ask").
    public func post(project: String, instructable: Data) async throws -> PostResult {
        guard let source else { throw QueueError.unreachable(Self.noSourceProblem) }
        let gen = generation
        let result = try await source.post(project: project, instructable: instructable)
        if gen == generation { await refresh() }
        return result
    }

    public func menuBarState(showCount: Bool, away: Bool) -> MenuBarState {
        MenuBarState.from(items: items, reachable: reachable, showCount: showCount, offlineReason: problem, away: away)
    }

    private func load(_ id: String, from source: any QueueSource, generation gen: Int) async {
        do {
            let detail = try await source.get(id)
            guard gen == generation else { return }
            details[id] = detail
            tickCache[id] = nil
            detailFailed.remove(id)
        } catch QueueError.notFound {
            guard gen == generation else { return }
            // The open ask keeps its cached detail when it leaves the queue (§4.7, "Ask closed while open").
            if id != navigation.selectedID { details[id] = nil }
        } catch {
            // Keep the cached detail; the next refresh retries.
            guard gen == generation else { return }
            if details[id] == nil { detailFailed.insert(id) }
        }
    }

    private func publishState() {
        reachable = listOK && listenerProblem == nil
        problem = listenerProblem ?? listProblem
        onStateChange?()
    }
}

/// What an ask's step tree is built from (DetailModel.make): the instructable's steps and
/// verify, or a legacy ask's cmd. Equal sources give equal trees.
struct StepSource: Equatable {
    var steps: [Step]?
    var verify: Step?
    var cmd: String?

    init(_ item: WireItem) {
        if let ins = item.instructable {
            steps = ins.steps
            verify = ins.verify
        } else {
            cmd = item.payload.cmd
        }
    }
}

extension Store: PanelViewModel {
    public var queue: QueueSnapshot {
        QueueSnapshot.build(
            open: items, closed: recentlyClosed, grouping: grouping, filter: filter,
            ticks: { self.ticks(for: $0) }, drafts: drafts, closedBy: { self.closedBy($0) },
            sourceKey: sourceKey, loadedOnce: loadedOnce, reachable: reachable, problem: listProblem,
            waitedTenSeconds: swappedAt.map { now().timeIntervalSince($0) >= DetailLoadState.timeout } ?? false,
            manualRefreshing: manualRefreshing, updated: lastListAt.map { ClockText.time($0) } ?? "")
    }

    public func detail(_ id: String) -> DetailSnapshot? {
        guard let item = item(for: id) else { return nil }
        let (previous, next) = navigation.neighbours(of: id, visibleOrder: visibleOrder, closedOrder: closedShown.map(\.id))
        let load = DetailLoadState.resolve(hasModel: details[id] != nil, requestedAt: detailRequestedAt[id], now: now(),
                                           failed: detailFailed.contains(id))
        return DetailSnapshot.build(
            item: item, detail: details[id], ticks: ticks(for: id), load: load, reply: replyStates[id] ?? .idle,
            draft: drafts[id], pendingChoice: pendingChoice[id], busy: replyStates[id] == .sending, previous: previous, next: next,
            closedBy: closedBy(item))
    }

    public var status: PanelStatus {
        PanelStatus.make(StatusInputs(
            sourceKey: sourceKey, reachable: reachable, loadedOnce: loadedOnce, problem: listOK ? nil : listProblem,
            configNote: configNote, listenerNote: listenerProblem, away: away, sendingCloses: sendingCloses))
    }

    public func keyContext(textFieldFocused: Bool, popoverOpen: Bool, closedHeaderFocused: Bool) -> KeyContext {
        let selected = listSelection.flatMap { item(for: $0) }
        let opened = navigation.selectedID.flatMap { item(for: $0) }
        return KeyContext(
            mode: opened == nil ? .list : .detail, textFieldFocused: textFieldFocused, popoverOpen: popoverOpen,
            undoAvailable: !pending.isEmpty, filterOn: filter != nil,
            selectionOpen: selected.map { $0.status == "open" },
            selectionHasProject: !(selected?.projectId ?? "").isEmpty, closedHeaderFocused: closedHeaderFocused,
            askOpen: opened.map { $0.status == "open" } ?? true, askHasProject: !(opened?.projectId ?? "").isEmpty,
            choiceCount: opened?.instructable?.reply?.choices?.count ?? 0,
            hasDraftOrPick: opened.map { primaryAction(for: $0.id) == .sendAndDone } ?? false)
    }

    /// The ask a key acts on: the open detail, else the selected row.
    private var target: String? { navigation.selectedID ?? listSelection }

    public func perform(_ command: PanelCommand) {
        switch command {
        case .closePopover, .endEditing, .focusReply, .setClosedExpanded:
            break   // view state: the view handles these before calling perform
        case .back: back()
        case .hide: shell.hide()
        case .refresh: refresh()
        case .openSettings: shell.openSettings(nil)
        case .undoClose: undo()
        case .quit: shell.quit()
        case .dock(let edge): shell.dock(edge)
        case .switchGrouping: setGrouping(grouping == .project ? .urgency : .project)
        case .clearFilter: setFilter(nil)
        case .showOnlyProject:
            if let id = target, let project = item(for: id)?.projectId, !project.isEmpty { setFilter(project) }
        case .openSelection: if let id = listSelection { open(id) }
        case .done: if let id = target { close(id, .done) }
        case .sendAndDone: if let id = target { sendAndDone(id) }
        case .skip: if let id = target { close(id, .declined) }
        case .reopen: if let id = target { reopen(id) }
        case .copyLink: if let id = target { copyLink(id) }
        case .previousAsk, .nextAsk:
            guard let id = navigation.selectedID else { return }
            let (previous, next) = navigation.neighbours(of: id, visibleOrder: visibleOrder, closedOrder: closedShown.map(\.id))
            if case .ask(let other) = command == .previousAsk ? previous : next { open(other) }
        case .tickCurrent: if let id = navigation.selectedID { tickCurrent(in: id) }
        case .untickLast: if let id = navigation.selectedID { untickLast(in: id) }
        case .copyCurrentCode:
            if let leaf = currentLeaf, let code = leaf.code { shell.copy(Sanitize.copyText(code)) }
        case .openCurrentURL:
            if let leaf = currentLeaf, let raw = leaf.url, LinkDisplay.isWeb(raw), let url = URL(string: raw) { shell.openURL(url) }
        case .pickChoice(let index): if let id = target { pendingChoice[id] = index }
        }
    }

    private var currentLeaf: DetailModel.Node? {
        guard let id = navigation.selectedID, let nodes = nodes(for: id),
              let path = Flow.currentStep(ticks: ticks(for: id), nodes: nodes) else { return nil }
        return Flow.leaves(of: nodes).first { $0.path == path }
    }

    public func refresh() { Task { await refresh(manual: true) } }
    public func reopen(_ id: String) { Task { await reopen(id) } }
    public func sendReply(_ id: String) { Task { _ = await sendReply(id) } }
    public func sendChoice(_ id: String) { Task { _ = await sendChoice(id) } }
    public func sendAndDone(_ id: String) { Task { await sendAndDone(id) } }
    public func performNoticeAction() { Task { await performNoticeAction() } }

    public func copyLink(_ id: String) { shell.copy("relay://i/\(id)") }

    public func retryDetail(_ id: String) {
        detailFailed.remove(id)
        detailRequestedAt[id] = now()
        scheduleTimeoutTick()
        guard let source else { return }
        let gen = generation
        Task { await self.load(id, from: source, generation: gen) }
    }
}
