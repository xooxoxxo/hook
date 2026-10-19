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
    /// The open detail. A forwarder for the 0.5 views until Task 52.
    public var selectedID: String? { navigation.selectedID }
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
    @Published public private(set) var busyID: String?
    @Published public private(set) var refreshing = false
    /// "none", "local" or "mailbox:<host>"; ticks and the Connect tab key on it.
    @Published public private(set) var sourceKey = SourceKey.none
    @Published public var actionError: String?
    /// One dismissible message: corrupt queue, save failed, config error, already running.
    @Published public var banner: String?

    /// Items that appeared since the previous list (never on the first list after launch or a swap).
    public var onNewItems: (@MainActor ([WireItem]) -> Void)?
    /// After items or reachability change; AppDelegate recomputes the menu bar.
    public var onStateChange: (@MainActor () -> Void)?

    public static let noSourceProblem = "No queue is set up"

    private var source: (any QueueSource)?
    private var pollSeconds = RelayConfig.defaultPollSeconds
    /// Bumped by every swap; results started under an older value are dropped.
    private var generation = 0
    private var watchTask: Task<Void, Never>?
    private var loadedOnce = false
    private var inFlight: Task<Void, Never>?
    /// Bumped by every refresh that starts a list; only the latest one clears `inFlight`.
    private var refreshCount = 0
    private var lastLinkRefresh: ContinuousClock.Instant?
    private var listOK = false
    private var listProblem: String? = Store.noSourceProblem
    private var listenerProblem: String?
    /// The source's open list, pending asks included.
    private var listed: [WireItem] = []
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

    public init(defaults: UserDefaults = .standard, now: @escaping @MainActor () -> Date = { Date() }) {
        self.defaults = defaults
        self.now = now
        self.grouping = PanelPrefs.grouping(defaults)
    }

    /// Swap: 1 bump the generation; 2 stop the poll or stream; 3 clear the
    /// details, items and not-found, and restore the source's saved selection and
    /// filter (the open detail closes); 4 the next first load never
    /// notifies; 5 subscribe or poll, and refresh.
    public func swap(to source: (any QueueSource)?, identity: SourceIdentity, pollSeconds: Int) {
        // Closes still held back belong to the old source: send them now.
        flushAll(to: self.source)
        generation += 1
        watchTask?.cancel()
        watchTask = nil
        inFlight = nil
        refreshing = false

        navigation = PanelNavigation(listSelection: PanelPrefs.selection(defaults, sourceKey: identity.key))
        filter = PanelPrefs.filter(defaults, sourceKey: identity.key)
        lastListAt = nil
        details = [:]
        tickCache = [:]
        tickHistory = [:]
        expandedDone = [:]
        detailAnchor = [:]
        listed = []
        items = []
        sending = []
        recentlyClosed = []
        closedActors = [:]
        quietIDs = []
        notFoundID = nil
        actionError = nil
        busyID = nil

        loadedOnce = false
        polling = false
        self.source = source
        self.identity = identity
        self.sourceKey = identity.key
        self.pollSeconds = max(1, pollSeconds)
        listOK = false
        listProblem = source == nil ? Self.noSourceProblem : nil
        publishState()

        guard let source else { return }
        watchTask = watch(source)
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
            updateItems()
            listOK = true
            listProblem = nil
            lastListAt = now()
            for id in diff.removed where id != selectedID {
                details[id] = nil
            }
            publishState()
            var toLoad = diff.added + diff.changed
            if let selected = selectedID, !toLoad.contains(selected) {
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
            publishState()
        }
    }

    /// The 0.5 views' entry point.
    public func select(_ id: String?) {
        if let id { open(id) } else { back() }
    }

    public func open(_ id: String) {
        let listed = visibleOrder.contains(id) || closedShown.contains { $0.id == id }
        navigation.open(id, listed: listed)
        saveSelection()
        notFoundID = nil
        actionError = nil
        loadIfMissing(id)
    }

    public func back() {
        navigation.back()
        notFoundID = nil
        actionError = nil
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
        select(id)
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

    /// Done or Skip, as the owner, held back for Undo: the ask leaves the list at
    /// once, the panel goes back to the queue, and the close is sent when its
    /// deadline passes (or on quit).
    public func close(_ id: String, _ verdict: Verdict, title: String) {
        guard source != nil else { return }
        pending.add(id: id, verdict: verdict, note: nil, title: title, now: now())
        recentlyClosed.removeAll { $0.id == id }
        actionError = nil
        if selectedID == id {
            navigation.back()
            notFoundID = nil
        }
        updateItems()
        publishState()
        startTicker()
    }

    /// Takes back the latest held-back close; the ask returns where it was.
    public func undoLatest() {
        guard pending.undoLatest() != nil else { return }
        updateItems()
        publishState()
    }

    /// Before quitting: sends every held-back close at once. The caller caps the wait.
    public func sendAllPending() async {
        guard let source else { return }
        let all = pending.drainAll()
        guard !all.isEmpty else { return }
        await withTaskGroup(of: Void.self) { group in
            for close in all {
                group.addTask {
                    _ = try? await source.resolve(close.id, verdict: close.verdict, note: close.note)
                }
            }
        }
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
            details[id] = nil
            quietIDs.insert(id)
            recentlyClosed.removeAll { $0.id == id }
            await freshRefresh()
        } catch {
            guard gen == generation else { return }
            banner = "Reopen failed: \(error.localizedDescription)"
            noteStoreFailure(error)
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

    /// Returns true once nothing is held back.
    private func sendDue() -> Bool {
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
    /// the send has come back; on failure it reappears and the banner says why.
    private func send(_ close: PendingClose, via source: any QueueSource, generation gen: Int) async {
        do {
            _ = try await source.resolve(close.id, verdict: close.verdict, note: close.note)
            guard gen == generation else { return }
            details[close.id] = nil
            await freshRefresh()
            guard gen == generation else { return }
            sending.remove(close.id)
            updateItems()
        } catch {
            guard gen == generation else { return }
            sending.remove(close.id)
            updateItems()
            publishState()
            let label = close.verdict == .done ? "Done" : "Skip"
            banner = "\(label) failed for “\(close.title)”: \(error.localizedDescription)"
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

    /// Sends a reply event. Returns true on success so the caller can clear its field.
    public func reply(_ id: String, text: String) async -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let source, !trimmed.isEmpty, busyID == nil else { return false }
        let gen = generation
        busyID = id
        actionError = nil
        defer { if gen == generation { busyID = nil } }
        do {
            _ = try await source.reply(id, text: trimmed)
            guard gen == generation else { return false }
            await load(id, from: source, generation: gen)
            return true
        } catch {
            guard gen == generation else { return false }
            actionError = "Reply failed: \(error.localizedDescription)"
            noteStoreFailure(error)
            return false
        }
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
        } catch QueueError.notFound {
            guard gen == generation else { return }
            details[id] = nil
        } catch {
            // Keep the cached detail; the next refresh retries.
        }
    }

    private func noteStoreFailure(_ error: any Error) {
        if case QueueError.storeFailed? = error as? QueueError {
            banner = error.localizedDescription
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
