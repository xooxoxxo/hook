import Foundation
import RelayCore

/// What `Store.checkLink(_:)` found for a link's ask.
public enum LinkCheck: Equatable, Sendable {
    /// In the open queue.
    case open
    /// Held back, or a list that succeeded doesn't have it.
    case closed
    /// Not checked: no source yet, a check ran in the last 5 seconds, or the list failed.
    case unknown
}

/// The app's state over one `QueueSource` at a time: the open queue, fetched
/// details, the selection, and the owner's actions. Lives in RelayUI so the
/// gallery and tests can drive it; views reach it through PanelViewModel.
@MainActor public final class Store: ObservableObject {
    /// The open queue as shown: the source's list without the asks held back
    /// for Undo or being sent. Every list, count and badge reads this.
    @Published public private(set) var items: [WireItem] = [] { didSet { queueInputChanged() } }
    /// Done and Skip held back for `PendingCloses.delay` seconds so they can be undone.
    @Published public private(set) var pending = PendingCloses()
    /// Asks closed in the last 24 hours, newest first, without any still held back.
    @Published public private(set) var recentlyClosed: [WireItem] = [] { didSet { queueInputChanged() } }
    /// A row's ticks are checked against its fetched detail's steps, so a new detail rebuilds the queue.
    /// A new detail also settles the answer drafts: one its events show as sent goes.
    @Published public private(set) var details: [String: AskDetail] = [:] {
        didSet {
            settleAnswerDrafts()
            queueInputChanged()
        }
    }
    /// The highlighted row and the open detail.
    @Published public var navigation = PanelNavigation() { didSet { dropNoticeOfLeftAsk() } }
    /// Unsent reply text per ask. Memory only: the owner's text is never written to disk unasked.
    /// Only whether a draft has text reaches the queue (its draft mark), so typing doesn't rebuild it.
    @Published public var drafts: [String: String] = [:] {
        didSet {
            let withText = Set(drafts.compactMap { QueueSnapshot.hasText($0.value) ? $0.key : nil })
            guard withText != draftsWithText else { return }
            draftsWithText = withText
            queueInputChanged()
        }
    }
    private var draftsWithText: Set<String> = []
    /// The picked, unsent choice index per ask. Memory only.
    @Published public var pendingChoice: [String: Int] = [:]
    /// Unsent step answers per ask, then step path. Memory only, like `drafts`: they don't survive a quit.
    @Published public var answerDrafts: [String: [String: AnswerDraft]] = [:]
    /// An answers send in flight, or why the last one failed, per ask.
    @Published public private(set) var answerStates: [String: AnswerSendState] = [:]
    /// The answered paths per ask, from its cached detail's events, keyed on the event count
    /// and last seq so a queue rebuild doesn't re-read every answer (QueueLayout.summary).
    private var answeredCache: [String: (key: [Int], paths: Set<String>)] = [:]
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
    /// One Notice at a time; the newest replaces the older; only ✕ or its action clears it,
    /// except a Notice about the open ask, which also goes when the owner leaves that ask.
    @Published public private(set) var notice: PanelNotice?
    /// A close reached the source (sent after Undo, at quit, or before a swap) or an ask was
    /// reopened: remove its delivered notification.
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
    /// Upcoming steps the owner expanded by hand, by ask; node paths. Memory only, like expandedDone.
    @Published public var expandedTodo: [String: Set<String>] = [:]
    /// Asks whose sent reply the owner is changing (Change). Memory only; a sent reply leaves it.
    @Published public var editingReply: Set<String> = []
    /// Answered step questions the owner is changing, per ask, by path. Memory only; a send leaves it.
    @Published public var editingAnswers: [String: Set<String>] = [:]
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
    /// Bumped when a load has waited `DS.Timing.detailLoadTimeout`, so views read the
    /// snapshots again and "Still trying…" / "Couldn't load" show with no other change.
    @Published public private(set) var stateTick = 0 { didSet { queueInputChanged() } }
    /// The wait behind `stateTick`; tests pass an immediate one.
    let timeoutSleep: @Sendable (Duration) async -> Void
    /// The pending timeout waits, by token; a swap cancels them all.
    private var stateTimers: [UUID: Task<Void, Never>] = [:]
    /// The real timeout wait, a nonisolated function for the same reason as `taskSleep`.
    nonisolated static func timeoutTaskSleep(_ duration: Duration) async {
        try? await Task.sleep(for: duration)
    }
    @Published public private(set) var grouping: QueueGrouping { didSet { queueInputChanged() } }
    /// The raw project string; nil = All Projects.
    @Published public private(set) var filter: String? { didSet { queueInputChanged() } }
    @Published public private(set) var manualRefreshing = false { didSet { queueInputChanged() } }
    /// When the last list came back.
    public private(set) var lastListAt: Date? { didSet { queueInputChanged() } }
    @Published public private(set) var notFoundID: String?
    /// The last list succeeded and the listener has no problem.
    @Published public private(set) var reachable = false { didSet { queueInputChanged() } }
    /// Why the source is offline; shown in the footer and the menu-bar tooltip.
    @Published public private(set) var problem: String?
    /// A list is running. No view shows it (the header spinner is `manualRefreshing`), so it isn't published.
    public private(set) var refreshing = false
    /// "none", "local" or "mailbox:<host>"; ticks and the Connect tab key on it.
    @Published public private(set) var sourceKey = SourceKey.none { didSet { queueInputChanged() } }

    /// What the queue view draws. Rebuilt only when one of its inputs changes, and
    /// published only when the rebuilt one differs, so a list that changes nothing
    /// re-renders nothing.
    @Published public private(set) var queue: QueueSnapshot
    /// The sections, their row order and the closed rows behind `queue`, kept with it.
    private var shownSections: [QueueSection] = []
    private var shownOrder: [String] = []
    private var shownClosed: [WireItem] = []
    /// Above 0 while a batch of input changes runs; the queue is rebuilt once at its end.
    private var queueHolds = 0
    private var queueStale = false
    /// How many times the queue snapshot was built; tests check a list that changes nothing builds none.
    private(set) var queueBuilds = 0

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
    var loadedOnce = false { didSet { queueInputChanged() } }
    private var inFlight: Task<Void, Never>?
    /// Bumped by every refresh that starts a list; only the latest one clears `inFlight`.
    private var refreshCount = 0
    private var lastLinkRefresh: ContinuousClock.Instant?
    var listOK = false
    /// The last list came through: `items` is the source's open list, not a placeholder.
    public var listLoaded: Bool { loadedOnce && listOK }
    var listProblem: String? = Store.noSourceProblem { didSet { queueInputChanged() } }
    var listenerProblem: String?
    /// The source's open list, pending asks included.
    var listed: [WireItem] = []
    /// Closes taken off `pending` whose send hasn't finished (or whose list hasn't caught up).
    private var sending: Set<String> = []
    /// Closes the quit-time flush drained from `pending` whose resolves haven't all finished.
    private var draining: Set<String> = []
    private var ticker: Task<Void, Never>?
    /// "id completedAt" → the closing event's actor, so each close is fetched once.
    /// "" when the closing event names no actor, so it isn't fetched again.
    private var closedActors: [String: String] = [:] { didSet { queueInputChanged() } }
    /// The ids `TickStore.prune` last kept; a list with the same ids skips the prune.
    private var prunedKeep: Set<String>?
    /// Reopened asks: their return to the list is not a new ask to announce.
    private var quietIDs: Set<String> = []

    public static let closedWindow: TimeInterval = DS.Timing.closedWindow

    let defaults: UserDefaults
    /// The clock for held closes and staleness; tests pass their own.
    let now: @MainActor () -> Date
    /// What the Store shows now; a different identity swaps the source.
    @Published public private(set) var identity = SourceIdentity(key: SourceKey.none, mailbox: nil)
    /// The source has no change stream, so a timer lists every pollSeconds.
    private var polling = false

    public init(defaults: UserDefaults = .standard, now: @escaping @MainActor () -> Date = { Date() },
                sentHold: Duration = .seconds(DS.Motion.sentHold),
                sleep: (@Sendable (Duration) async throws -> Void)? = nil,
                timeoutSleep: (@Sendable (Duration) async -> Void)? = nil) {
        self.defaults = defaults
        self.now = now
        self.sentHold = sentHold
        self.sleep = sleep ?? Store.taskSleep
        self.timeoutSleep = timeoutSleep ?? Store.timeoutTaskSleep
        let grouping = PanelPrefs.grouping(defaults)
        self.grouping = grouping
        queue = QueueSnapshot.build(
            open: [], closed: [], grouping: grouping, filter: nil, ticks: { _ in [] }, drafts: [:], closedBy: { _ in nil },
            sourceKey: SourceKey.none, loadedOnce: false, reachable: false, problem: Store.noSourceProblem,
            waitedTenSeconds: false, manualRefreshing: false, updated: "")
        rebuildQueue()
    }

    /// Swap: 1 bump the generation; 2 stop the poll or stream; 3 clear the
    /// details, items and not-found, and restore the source's saved selection and
    /// filter (the open detail closes); 4 the next first load never
    /// notifies; 5 subscribe or poll, and refresh.
    public func swap(to source: (any QueueSource)?, identity: SourceIdentity, pollSeconds: Int) {
        holdingQueue { swapState(to: source, identity: identity, pollSeconds: pollSeconds) }
        guard let source else { return }
        scheduleTimeoutTick()
        watchTask = watch(source)
    }

    private func swapState(to source: (any QueueSource)?, identity: SourceIdentity, pollSeconds: Int) {
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
        expandedTodo = [:]
        editingReply = []
        editingAnswers = [:]
        detailAnchor = [:]
        replyStates = [:]
        answerStates = [:]
        answeredCache = [:]
        sentResets.values.forEach { $0.task.cancel() }
        sentResets = [:]
        listed = []
        items = []
        sending = []
        recentlyClosed = []
        closedActors = [:]
        prunedKeep = nil
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
    }

    /// One wait of `DS.Timing.detailLoadTimeout`, then a `stateTick` bump. The next swap cancels it.
    private func scheduleTimeoutTick() {
        let token = UUID(), sleep = timeoutSleep
        stateTimers[token] = Task { [weak self] in
            await sleep(.seconds(DS.Timing.detailLoadTimeout))
            guard !Task.isCancelled, let self, self.stateTimers.removeValue(forKey: token) != nil else { return }
            self.stateTick += 1
        }
    }

    /// A new interval restarts only the timer: no swap, so the selection, items,
    /// details and held closes stay. A source with a change stream ignores it.
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
    /// "Hook is already running") makes the source unreachable with that reason.
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

    /// What a link from outside the app (loopback, relay:// or a notification click)
    /// finds for `id`: `.open` when it is in the open queue, `.closed` when it is held
    /// back or a fresh list confirms it is gone, `.unknown` when nothing was checked
    /// (no source yet, a refresh in the last 5 seconds, or the list failed).
    public func checkLink(_ id: String) async -> LinkCheck {
        if items.contains(where: { $0.id == id }) { return .open }
        if hidden.contains(id) { return .closed }
        guard source != nil else { return .unknown }
        let now = ContinuousClock.now
        if let last = lastLinkRefresh, now - last < .seconds(DS.Timing.linkRecheck) { return .unknown }
        lastLinkRefresh = now
        await refresh()
        if items.contains(where: { $0.id == id }) { return .open }
        return listOK ? .closed : .unknown
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
            holdingQueue { applyList(fresh, diff: diff) }
            // The open ask's detail first, on its own, so it never waits for the others;
            // the rest arrive as one change, not one re-render per ask.
            var toLoad = diff.added + diff.changed
            if let selected = navigation.selectedID {
                toLoad.removeAll { $0 == selected }
                await load(selected, from: source, generation: gen)
                guard gen == generation else { return }
            }
            var fetched: [(id: String, result: DetailFetch)] = []
            for id in toLoad {
                fetched.append((id, await fetch(id, from: source)))
                guard gen == generation else { return }
            }
            apply(fetched)
            let announce = diff.added.filter { !quietIDs.contains($0) }
            quietIDs.subtract(diff.added)
            if loadedOnce, !announce.isEmpty {
                onNewItems?(items.filter { announce.contains($0.id) })
            }
            await loadClosed(from: source, generation: gen)
            guard gen == generation else { return }
            if !loadedOnce { loadedOnce = true }
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

    /// The synchronous part of a good list, as one queue change.
    private func applyList(_ fresh: [WireItem], diff: QueueDiff) {
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
        if listProblem != nil { listProblem = nil }
        offlineNoticed = false
        if showsOfflineNotice { notice = nil }
        lastListAt = now()
        let gone = diff.removed.filter { $0 != navigation.selectedID && details[$0] != nil }
        if !gone.isEmpty {
            var next = details
            for id in gone { next[id] = nil }
            details = next
        }
        publishState()
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

    public var sections: [QueueSection] { shownSections }
    public var visibleOrder: [String] { shownOrder }
    public var closedShown: [WireItem] { shownClosed }
    public var hiddenCount: HiddenCount { queue.hidden }
    public var menuProjects: [MenuProject] { queue.projects }

    /// The header spinner shows only for this one; background polls change nothing there.
    public func refresh(manual: Bool) async {
        if manual { manualRefreshing = true }
        await refresh()
        if manual { manualRefreshing = false }
    }

    /// How old the last list may be before showing the panel in mailbox mode lists again.
    public static let staleAfter: TimeInterval = DS.Timing.staleList

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

    /// The ask's step tree: from the fetched detail's item, else from the list item. The
    /// item shapes the nodes; the cached detail's events fill the answers, as in `DetailSnapshot`,
    /// so ⌘T, ⌘O and ticking see what is answered.
    func nodes(for id: String) -> [DetailModel.Node]? {
        guard let item = item(for: id) else { return nil }
        return stepTree(item, events: details[id]?.events ?? [])
    }

    /// Ticks key on fingerprints only, so their loads pass no events.
    private func stepTree(_ item: WireItem, events: [Event] = []) -> [DetailModel.Node] {
        stepTreeBuilds += 1
        return DetailModel.make(item: item, events: events).nodes
    }

    /// The answered paths of an ask whose detail is cached; nil without one.
    private func answered(_ id: String) -> Set<String>? {
        guard let events = details[id]?.events else { return nil }
        let key = [events.count, events.last?.seq ?? 0]
        if let hit = answeredCache[id], hit.key == key { return hit.paths }
        let paths = Set(Answers.latest(events).keys)
        answeredCache[id] = (key, paths)
        return paths
    }

    /// The ticked leaves of the ask's current tree whose fingerprint matches; a tick
    /// for a removed or edited step is dropped, so no count ever includes it.
    /// Cheap on a hit: rows call this on every render, so the tree is built only on a miss.
    public func ticks(for id: String) -> Set<String> {
        guard let item = item(for: id) else { return [] }
        return ticks(id, item: item)
    }

    /// `ticks(for:)` for an item in hand: the queue build has every row's item, so it skips the lookup.
    private func ticks(_ id: String, item listedItem: WireItem) -> Set<String> {
        let item = details[id]?.item ?? listedItem
        let source = StepSource(item)
        if let cached = tickCache[id], cached.source == source { return cached.ticks }
        let loaded = TickStore.load(defaults, sourceKey: sourceKey, id: id, nodes: stepTree(item))
        tickCache[id] = (source, loaded)
        return loaded
    }

    /// A leaf flips; a parent ticks or unticks all its sub-steps (Flow.toggle). Saves.
    /// A locked step (Flow.lockedPaths) is left as it is, and so are a parent's locked sub-steps.
    public func toggleTick(_ path: String, in id: String) {
        guard let nodes = nodes(for: id), let node = Flow.flattened(nodes).first(where: { $0.path == path }) else { return }
        let before = ticks(for: id)
        let after = Flow.toggle(node, ticks: before, locked: Set(Flow.lockedPaths(nodes: nodes, ticks: before)))
        guard after != before else { return }
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
        // The detail reads ticks too, and an ask outside the filter changes no queue row.
        objectWillChange.send()
        let leaves = ticks.intersection(Flow.leaves(of: nodes).map(\.path))
        tickCache[id] = item(for: id).map { (StepSource($0), leaves) }
        TickStore.save(defaults, sourceKey: sourceKey, id: id, ticks: leaves, nodes: nodes)
        queueInputChanged()
    }

    /// After a good list of this source: keeps ticks of open asks (held ones are still
    /// listed), of Recently closed and of the open detail, whatever the filter.
    /// Reading every defaults key is costly, so a list with the same ids as the last prune skips it.
    /// The in-memory tick cache and load times keep the same ids.
    func pruneTicks() {
        guard reachable, !listed.isEmpty else { return }
        var keep = Set(listed.map(\.id)).union(recentlyClosed.map(\.id)).union(sending)
        if let selected = navigation.selectedID { keep.insert(selected) }
        tickCache = tickCache.filter { keep.contains($0.key) }
        detailRequestedAt = detailRequestedAt.filter { keep.contains($0.key) }
        guard keep != prunedKeep else { return }
        prunedKeep = keep
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

    /// Back, Esc, Next Ask or opening another ask leaves the closed ask, and its Notice with it.
    private func dropNoticeOfLeftAsk() {
        guard let id = notice?.detailAskID, navigation.selectedID != id else { return }
        notice = nil
        sessionClosedNext = nil
    }

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
        case .storeFailed, .settingsReloaded, .updating, .resumeFailed:
            break
        }
    }

    private var showsOfflineNotice: Bool {
        if case .offlineCached? = notice { return true }
        return false
    }

    /// Before quitting: sends every held-back close at once. The caller caps the wait.
    /// The Undo bar shown while they go ("Sending", Undo disabled) is the one from
    /// before the drain, kept in `sendingUndo` until every send has finished.
    public func sendAllPending() async {
        guard let source else { return }
        let shown = undoInfo
        let all = pending.drainAll()
        guard !all.isEmpty else { return }
        draining = Set(all.map { $0.id })
        sendingUndo = shown
        publishState()
        let sent = await withTaskGroup(of: String?.self) { group in
            for close in all {
                group.addTask {
                    (try? await source.resolve(close.id, verdict: close.verdict, note: close.note)) != nil ? close.id : nil
                }
            }
            var ids: [String] = []
            for await id in group { if let id { ids.append(id) } }
            return ids
        }
        draining = []
        sent.forEach { onCloseSent?($0) }
        sendingUndo = nil
        publishState()
    }

    public var hasPendingCloses: Bool { !pending.isEmpty }

    /// Closes that are hidden but not yet resolved: held for Undo, sending, or in the
    /// quit-time flush. Their notifications stay until the source confirms the close.
    public var heldCloseIDs: Set<String> {
        sending.union(draining).union(pending.ids)
    }

    /// The actor of the event that closed `item` ("owner", "session"), once fetched.
    public func closedBy(_ item: WireItem) -> String? {
        closedActors[Self.closedKey(item)].flatMap { $0.isEmpty ? nil : $0 }
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
            } else if let detail = try? await source.get(item.id) {
                guard gen == generation else { return }
                actors[key] = DetailModel.make(detail).closedBy ?? ""
            }
        }
        guard gen == generation else { return }
        holdingQueue {
            if actors != closedActors { closedActors = actors }
            if closed != recentlyClosed { recentlyClosed = closed }
        }
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
                try? await Task.sleep(for: .seconds(DS.Timing.holdTick))
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
        // `due` mutates the published `pending`, which re-renders the panel: only call it when something is due.
        let time = now()
        let due = pending.hasDue(now: time) ? pending.due(now: time) : []
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
        let onCloseSent = self.onCloseSent
        Task.detached {
            for close in all {
                do {
                    _ = try await old.resolve(close.id, verdict: close.verdict, note: close.note)
                    await onCloseSent?(close.id)
                } catch {
                    NSLog("Hook: a held-back close couldn't be sent before the queue changed: %@",
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
        return await send(text, for: id) {
            self.drafts[id] = nil
            self.editingReply.remove(id)
        }
    }

    public func sendChoice(_ id: String) async -> Bool {
        guard let index = pendingChoice[id], let choices = item(for: id)?.instructable?.reply?.choices,
              choices.indices.contains(index), replyStates[id] != .sending else { return false }
        return await send(ReplyText.wire(choice: choices[index]), for: id) {
            self.pendingChoice[id] = nil
            self.editingReply.remove(id)
        }
    }

    /// ⌘↩ / the primary button: Done, or send first and close only when every send worked.
    /// Order: the step answers, then the reply draft or pick, then Done; the first failure stops it.
    public func sendAndDone(_ id: String) async {
        guard primaryAction(for: id) == .sendAndDone else {
            close(id, .done)
            return
        }
        if answerStates[id] == .sending { return }
        if unsentAnswers(for: id).count > 0 {
            guard await sendAnswers(id) else { return }
        }
        if Flow.primaryAction(draft: drafts[id], choice: pendingChoice[id], sent: latestSentChoice(for: id),
                              sentText: AnswerEditing.latestText(replyLines(for: id))) == .sendAndDone {
            let hasText = AnswerEditing.isNewText(drafts[id] ?? "", sentText: AnswerEditing.latestText(replyLines(for: id)))
            let sent = hasText ? await sendReply(id) : await sendChoice(id)
            guard sent else { return }
        }
        close(id, .done)
    }

    /// What ⌘S sends for `id` now: drafts that differ from the sent answers, in document
    /// order, leaving out locked steps (Flow.lockedPaths). `only` limits it to those paths
    /// (one question's own Send). None while the ask is closed (R5).
    public func unsentAnswers(for id: String, only: Set<String>? = nil) -> UnsentAnswers {
        guard let drafts = answerDrafts[id], !drafts.isEmpty, let item = item(for: id), item.status == "open",
              let nodes = nodes(for: id) else { return .none }
        let locked = Set(Flow.lockedPaths(nodes: nodes, ticks: ticks(for: id)))
        return AnswerDrafts.unsent(drafts, nodes: nodes, locked: locked, only: only)
    }

    /// Sends the unsent answers (or only those at `only`) as one batch, then reloads the ask
    /// and drops the drafts it sent. False when there was nothing to send, a send is already
    /// running, or it failed (the reason is in `answerStates`).
    public func sendAnswers(_ id: String, only: Set<String>? = nil) async -> Bool {
        let unsent = unsentAnswers(for: id, only: only)
        guard unsent.count > 0, answerStates[id] != .sending else { return false }
        guard let source else {
            answerStates[id] = .failed(reason: AnswerDrafts.failureText(QueueError.unreachable(Self.noSourceProblem)))
            return false
        }
        let sent = answerDrafts[id] ?? [:]
        answerStates[id] = .sending
        let gen = generation
        do {
            _ = try await source.answer(id, answers: unsent.batch)
            guard gen == generation else { return false }
            await load(id, from: source, generation: gen)
            guard gen == generation else { return false }
            // A draft edited while the send was out stays.
            if var drafts = answerDrafts[id] {
                for path in unsent.paths where drafts[path] == sent[path] { drafts[path] = nil }
                answerDrafts[id] = drafts.isEmpty ? nil : drafts
            }
            if var editing = editingAnswers[id] {
                editing.subtract(unsent.paths)
                editingAnswers[id] = editing.isEmpty ? nil : editing
            }
            answerStates[id] = nil
            return true
        } catch {
            guard gen == generation else { return false }
            answerStates[id] = .failed(reason: AnswerDrafts.failureText(error))
            return false
        }
    }

    /// Drops every answer draft that the cached detail shows as sent (from here, or a Telegram tap).
    private func settleAnswerDrafts() {
        guard !answerDrafts.isEmpty else { return }
        var next = answerDrafts
        for (id, drafts) in answerDrafts {
            guard let detail = details[id] else { continue }
            let kept = AnswerDrafts.settled(drafts, nodes: DetailModel.make(detail).nodes)
            next[id] = kept.isEmpty ? nil : kept
        }
        if next != answerDrafts { answerDrafts = next }
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
        Flow.primaryAction(draft: drafts[id], choice: pendingChoice[id], sent: latestSentChoice(for: id),
                           unsentAnswers: unsentAnswers(for: id).count, sentText: AnswerEditing.latestText(replyLines(for: id)))
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

    public func menuBarState(unseen: Bool, away: Bool) -> MenuBarState {
        MenuBarState.from(items: items, reachable: reachable, unseen: unseen, offlineReason: problem, away: away)
    }

    private func load(_ id: String, from source: any QueueSource, generation gen: Int) async {
        let result = await fetch(id, from: source)
        guard gen == generation else { return }
        apply([(id, result)])
    }

    enum DetailFetch {
        case loaded(AskDetail)
        case notFound
        case failed
    }

    private func fetch(_ id: String, from source: any QueueSource) async -> DetailFetch {
        do {
            return .loaded(try await source.get(id))
        } catch QueueError.notFound {
            return .notFound
        } catch {
            return .failed
        }
    }

    /// Fetched details, as one change; an unchanged detail changes nothing.
    private func apply(_ fetched: [(id: String, result: DetailFetch)]) {
        var next = details
        for (id, result) in fetched {
            switch result {
            case .loaded(let detail):
                if next[id] != detail {
                    next[id] = detail
                    tickCache[id] = nil
                }
                detailFailed.remove(id)
            case .notFound:
                // The open ask keeps its cached detail when it leaves the queue, so it can still show as closed.
                if id != navigation.selectedID { next[id] = nil }
            case .failed:
                // Keep the cached detail; the next refresh retries.
                if next[id] == nil { detailFailed.insert(id) }
            }
        }
        dropStaleReplyChanges(next)
        if next != details { details = next }
    }

    /// Leaves Change on an ask whose untouched prefill a newer reply has overtaken.
    private func dropStaleReplyChanges(_ next: [String: AskDetail]) {
        for id in editingReply {
            let before = details[id]?.events ?? [], after = next[id]?.events ?? []
            guard before != after else { continue }
            let choices = item(for: id)?.instructable?.reply?.choices ?? []
            guard AnswerEditing.changeWentStale(before: ReplyText.lines(events: before),
                                                after: ReplyText.lines(events: after),
                                                draft: drafts[id], pick: pendingChoice[id],
                                                sentChoiceBefore: ReplyText.latestSentChoice(events: before, choices: choices))
            else { continue }
            editingReply.remove(id)
            drafts[id] = nil
            pendingChoice[id] = nil
        }
    }

    /// Assigns only what changed: `@Published` publishes on every assignment, equal or not.
    private func publishState() {
        let nowReachable = listOK && listenerProblem == nil
        if reachable != nowReachable { reachable = nowReachable }
        let nowProblem = listenerProblem ?? listProblem
        if problem != nowProblem { problem = nowProblem }
        onStateChange?()
    }

    private func queueInputChanged() {
        if queueHolds > 0 {
            queueStale = true
        } else {
            rebuildQueue()
        }
    }

    /// Runs `body` with queue rebuilds held, then rebuilds once if any input changed.
    private func holdingQueue(_ body: () -> Void) {
        queueHolds += 1
        body()
        queueHolds -= 1
        guard queueHolds == 0, queueStale else { return }
        queueStale = false
        rebuildQueue()
    }

    private func rebuildQueue() {
        queueBuilds += 1
        let sections = QueueLayout.sections(items: items, grouping: grouping, filter: filter)
        let closed = QueueLayout.closed(recentlyClosed, filter: filter)
        shownSections = sections
        shownOrder = QueueLayout.visibleOrder(sections)
        shownClosed = closed
        let next = QueueSnapshot.build(
            sections: sections, shownClosed: closed, open: items, grouping: grouping, filter: filter,
            ticks: { self.ticks($0.id, item: $0) }, answered: { self.answered($0.id) },
            hasDraft: { self.draftsWithText.contains($0) },
            closedBy: { self.closedBy($0) },
            sourceKey: sourceKey, loadedOnce: loadedOnce, reachable: reachable, problem: listProblem,
            waitedTenSeconds: swappedAt.map { now().timeIntervalSince($0) >= DS.Timing.detailLoadTimeout } ?? false,
            manualRefreshing: manualRefreshing, updated: lastListAt.map { ClockText.time($0) } ?? "")
        if next != queue { queue = next }
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
    public func detail(_ id: String) -> DetailSnapshot? {
        guard let item = item(for: id) else { return nil }
        let (previous, next) = navigation.neighbours(of: id, visibleOrder: visibleOrder, closedOrder: closedShown.map(\.id))
        let load = DetailLoadState.resolve(hasModel: details[id] != nil, requestedAt: detailRequestedAt[id], now: now(),
                                           failed: detailFailed.contains(id), timeout: DS.Timing.detailLoadTimeout)
        return DetailSnapshot.build(
            item: item, detail: details[id], ticks: ticks(for: id), load: load, reply: replyStates[id] ?? .idle,
            draft: drafts[id], pendingChoice: pendingChoice[id], busy: replyStates[id] == .sending, previous: previous, next: next,
            closedBy: closedBy(item), answerDrafts: answerDrafts[id] ?? [:], answerState: answerStates[id])
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
            hasDraftOrPick: opened.map { primaryAction(for: $0.id) == .sendAndDone } ?? false,
            hasUnsentAnswers: opened.map { unsentAnswers(for: $0.id).count > 0 } ?? false)
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
        case .sendAnswers: if let id = navigation.selectedID { sendAnswers(id) }
        }
    }

    private var currentLeaf: DetailModel.Node? {
        guard let id = navigation.selectedID, let nodes = nodes(for: id),
              let path = Flow.currentStep(ticks: ticks(for: id), nodes: nodes) else { return nil }
        // flattened, not leaves: the current item can be a parent's own question.
        return Flow.flattened(nodes).first { $0.path == path }
    }

    public func refresh() { Task { await refresh(manual: true) } }
    public func reopen(_ id: String) { Task { await reopen(id) } }
    public func sendReply(_ id: String) { Task { _ = await sendReply(id) } }
    public func sendChoice(_ id: String) { Task { _ = await sendChoice(id) } }
    public func sendAndDone(_ id: String) { Task { await sendAndDone(id) } }
    public func sendAnswers(_ id: String) { Task { _ = await sendAnswers(id) } }
    public func sendAnswer(_ id: String, path: String) { Task { _ = await sendAnswers(id, only: [path]) } }
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
