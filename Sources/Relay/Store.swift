import Foundation
import RelayCore

/// The app's state over one `QueueSource` at a time: the open queue, fetched
/// details, the selection, and the owner's actions.
@MainActor final class Store: ObservableObject {
    /// The open queue as shown: the source's list without the asks held back
    /// for Undo or being sent. Every list, count and badge reads this.
    @Published private(set) var items: [WireItem] = []
    /// Done and Skip held back for `PendingCloses.delay` seconds so they can be undone.
    @Published private(set) var pending = PendingCloses()
    @Published private(set) var details: [String: AskDetail] = [:]
    @Published private(set) var selectedID: String?
    @Published private(set) var notFoundID: String?
    /// The last list succeeded and the listener has no problem.
    @Published private(set) var reachable = false
    /// Why the source is offline; shown in the footer and the menu-bar tooltip.
    @Published private(set) var problem: String?
    @Published private(set) var busyID: String?
    @Published private(set) var refreshing = false
    /// "none", "local" or "mailbox:<host>"; ticks and the Connect tab key on it.
    @Published private(set) var sourceKey = "none"
    @Published var actionError: String?
    /// One dismissible message: corrupt queue, save failed, config error, already running.
    @Published var banner: String?

    /// Items that appeared since the previous list (never on the first list after launch or a swap).
    var onNewItems: (@MainActor ([WireItem]) -> Void)?
    /// After items or reachability change; AppDelegate recomputes the menu bar.
    var onStateChange: (@MainActor () -> Void)?

    static let noSourceProblem = "No queue is set up"

    private var source: (any QueueSource)?
    private var pollSeconds = RelayConfig.defaultPollSeconds
    /// Bumped by every swap; results started under an older value are dropped.
    private var generation = 0
    private var watchTask: Task<Void, Never>?
    private var loadedOnce = false
    private var inFlight: Task<Void, Never>?
    private var lastLinkRefresh: ContinuousClock.Instant?
    private var listOK = false
    private var listProblem: String? = Store.noSourceProblem
    private var listenerProblem: String?
    /// The source's open list, pending asks included.
    private var listed: [WireItem] = []
    /// Closes taken off `pending` whose send hasn't finished (or whose list hasn't caught up).
    private var sending: Set<String> = []
    private var ticker: Task<Void, Never>?

    init() {}

    /// Swap: 1 bump the generation; 2 stop the poll or stream; 3 clear
    /// the selection, details, items and not-found; 4 the next first load never
    /// notifies; 5 subscribe or poll, and refresh.
    func swap(to source: (any QueueSource)?, sourceKey: String, pollSeconds: Int) {
        // Closes still held back belong to the old source: send them now.
        flushAll(to: self.source)
        generation += 1
        watchTask?.cancel()
        watchTask = nil
        inFlight = nil
        refreshing = false

        selectedID = nil
        details = [:]
        listed = []
        items = []
        sending = []
        notFoundID = nil
        actionError = nil
        busyID = nil

        loadedOnce = false
        self.source = source
        self.sourceKey = sourceKey
        self.pollSeconds = max(1, pollSeconds)
        listOK = false
        listProblem = source == nil ? Self.noSourceProblem : nil
        publishState()

        guard let source else { return }
        let seconds = self.pollSeconds
        watchTask = Task { [weak self] in
            if let stream = await source.changes() {
                await self?.refresh()
                for await _ in stream {
                    guard !Task.isCancelled, let self else { return }
                    await self.refresh()
                }
            } else {
                while !Task.isCancelled {
                    guard let self else { return }
                    await self.refresh()
                    try? await Task.sleep(for: .seconds(seconds))
                }
            }
        }
    }

    /// Local mode: a listener problem ("Port … is in use by another app",
    /// "Relay is already running") makes the source unreachable with that reason.
    func setListenerProblem(_ text: String?) {
        guard listenerProblem != text else { return }
        listenerProblem = text
        publishState()
    }

    /// One list of the queue. A call made while one runs waits for that one.
    func refresh() async {
        if let inFlight { return await inFlight.value }
        let task = Task { await self.poll() }
        inFlight = task
        refreshing = true
        await task.value
        if inFlight == task {
            inFlight = nil
            refreshing = false
        }
    }

    /// Whether a link from outside the app (loopback or relay://) may open `id`:
    /// it must be in the open queue, after at most one refresh per 5 seconds.
    func acceptsLink(_ id: String) async -> Bool {
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
            if loadedOnce, !diff.added.isEmpty {
                onNewItems?(items.filter { diff.added.contains($0.id) })
            }
            loadedOnce = true
        } catch {
            guard gen == generation else { return }
            listOK = false
            listProblem = error.localizedDescription
            publishState()
        }
    }

    func select(_ id: String?) {
        selectedID = id
        notFoundID = nil
        actionError = nil
        if let id, details[id] == nil, let source {
            let gen = generation
            Task { await self.load(id, from: source, generation: gen) }
        }
    }

    /// Deep link target: select the item, fetch it, and fall back to a refresh
    /// and then "not found" when the source does not know the id.
    func focus(_ id: String) async {
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

    func item(for id: String) -> WireItem? {
        details[id]?.item ?? listed.first { $0.id == id }
    }

    func detail(for id: String) -> AskDetail? {
        details[id]
    }

    /// Done or Skip, as the owner, held back for Undo: the ask leaves the list at
    /// once, the panel goes back to the queue, and the close is sent when its
    /// deadline passes (or on quit).
    func close(_ id: String, _ verdict: Verdict, title: String) {
        guard source != nil else { return }
        pending.add(id: id, verdict: verdict, note: nil, title: title, now: Date())
        actionError = nil
        if selectedID == id {
            selectedID = nil
            notFoundID = nil
        }
        updateItems()
        publishState()
        startTicker()
    }

    /// Takes back the latest held-back close; the ask returns where it was.
    func undoLatest() {
        guard pending.undoLatest() != nil else { return }
        updateItems()
        publishState()
    }

    /// Before quitting: sends every held-back close at once. The caller caps the wait.
    func sendAllPending() async {
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

    var hasPendingCloses: Bool { !pending.isEmpty }

    /// Every id the open list was refreshed with, pending ones included (for tick pruning).
    var listedIDs: Set<String> { Set(listed.map(\.id)) }

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
        let due = pending.due(now: Date())
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
    func reply(_ id: String, text: String) async -> Bool {
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
    func post(project: String, instructable: Data) async throws -> PostResult {
        guard let source else { throw QueueError.unreachable(Self.noSourceProblem) }
        let gen = generation
        let result = try await source.post(project: project, instructable: instructable)
        if gen == generation { await refresh() }
        return result
    }

    func menuBarState(showCount: Bool) -> MenuBarState {
        MenuBarState.from(items: items, reachable: reachable, showCount: showCount, offlineReason: problem)
    }

    private func load(_ id: String, from source: any QueueSource, generation gen: Int) async {
        do {
            let detail = try await source.get(id)
            guard gen == generation else { return }
            details[id] = detail
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
