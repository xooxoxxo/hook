import Foundation
import RelayCore

/// The app's state over one `QueueSource` at a time: the open queue, fetched
/// details, the selection, and the owner's actions.
@MainActor final class Store: ObservableObject {
    @Published private(set) var items: [WireItem] = []
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

    init() {}

    /// Swap: 1 bump the generation; 2 stop the poll or stream; 3 clear
    /// the selection, details, items and not-found; 4 the next first load never
    /// notifies; 5 subscribe or poll, and refresh.
    func swap(to source: (any QueueSource)?, sourceKey: String, pollSeconds: Int) {
        generation += 1
        watchTask?.cancel()
        watchTask = nil
        inFlight = nil
        refreshing = false

        selectedID = nil
        details = [:]
        items = []
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
            let diff = QueueLogic.diff(old: items, new: fresh)
            items = fresh
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
                onNewItems?(fresh.filter { diff.added.contains($0.id) })
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
            if details[id] == nil, !items.contains(where: { $0.id == id }) {
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
        details[id]?.item ?? items.first { $0.id == id }
    }

    func detail(for id: String) -> AskDetail? {
        details[id]
    }

    /// Done or Skip, as the owner. On success the panel goes back to the queue.
    func resolve(_ id: String, _ verdict: Verdict) async {
        guard let source, busyID == nil else { return }
        let gen = generation
        busyID = id
        actionError = nil
        defer { if gen == generation { busyID = nil } }
        do {
            _ = try await source.resolve(id, verdict: verdict, note: nil)
            guard gen == generation else { return }
            if selectedID == id { selectedID = nil }
            details[id] = nil
            await refresh()
        } catch {
            guard gen == generation else { return }
            let label = verdict == .done ? "Done" : "Skip"
            actionError = "\(label) failed: \(error.localizedDescription)"
            noteStoreFailure(error)
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
