import CryptoKit
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
    @Published public internal(set) var pending = PendingCloses()
    /// Asks closed in the last 24 hours, newest first, without any still held back.
    @Published public internal(set) var recentlyClosed: [WireItem] = [] { didSet { queueInputChanged() } }
    /// A row's ticks are checked against its fetched detail's steps, so a new detail rebuilds the queue.
    /// A new detail also settles the answer drafts: one its events show as sent goes.
    @Published public internal(set) var details: [String: AskDetail] = [:] {
        didSet {
            settleAnswerDrafts()
            settleDoneWarnings()
            queueInputChanged()
        }
    }
    /// The panel screen logged last (`HookLog`), so a refresh doesn't log it again.
    var screens = HookLog.ScreenTracker()
    /// The highlighted row and the open detail. Leaving an ask also ends its Done warning.
    @Published public var navigation = PanelNavigation() {
        didSet {
            if navigation.selectedID != oldValue.selectedID, shell.isShown() { logScreen() }
            dropNoticeOfLeftAsk()
            if !doneWarnings.isEmpty, !doneWarnings.allSatisfy({ $0 == navigation.selectedID }) {
                doneWarnings = doneWarnings.filter { $0 == navigation.selectedID }
            }
        }
    }
    /// Unsent reply text per ask. Memory only: the owner's text is never written to disk unasked.
    /// Only whether a draft has text reaches the queue (its draft mark), so typing doesn't rebuild it.
    @Published public var drafts: [String: String] = [:] {
        didSet {
            settleDoneWarnings()
            let withText = Set(drafts.compactMap { QueueSnapshot.hasText($0.value) ? $0.key : nil })
            guard withText != draftsWithText else { return }
            draftsWithText = withText
            queueInputChanged()
        }
    }
    private var draftsWithText: Set<String> = []
    /// The picked, unsent choice index per ask. Memory only.
    @Published public var pendingChoice: [String: Int] = [:] { didSet { settleDoneWarnings() } }
    /// Unsent step answers per ask, then step path. Memory only, like `drafts`: they don't survive a quit.
    @Published public var answerDrafts: [String: [String: AnswerDraft]] = [:] { didSet { settleDoneWarnings() } }
    /// Asks whose bar shows the Done warning: Done was pressed with something unsent. Memory
    /// only; it ends on Esc, on either of its buttons, on leaving the ask, and once nothing
    /// is unsent any more (a Send in the ask, or answers arriving from elsewhere).
    @Published public private(set) var doneWarnings: Set<String> = []
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
    /// except a Notice about the open ask, which also goes when the owner leaves that ask,
    /// and a transient one, which goes after `DS.Motion.noticeHold` or when an ask opens.
    @Published public private(set) var notice: PanelNotice? {
        didSet { if notice != oldValue { noticeReset?.cancel(); noticeReset = nil } }
    }
    /// The running timer that clears a transient Notice.
    private var noticeReset: Task<Void, Never>?
    /// A close reached the source (sent after Undo, at quit, or before a swap) or an ask was
    /// reopened: remove its delivered notification.
    public var onCloseSent: (@MainActor (String) -> Void)?
    /// Text for VoiceOver to announce ("Ask reopened").
    public var onAnnounce: (@MainActor (String) -> Void)?
    /// The queueMoved Notice's "Show in Finder".
    public var onShowInFinder: (@MainActor (String) -> Void)?
    /// An owner act got 403 "unknown owner key": AppDelegate marks this Mac's key refused,
    /// so the next act goes without it.
    public var onOwnerKeyRefused: (@MainActor () -> Void)?
    /// Reset Review Records… made a new seal: each owner key, marked under the old one, reads again.
    public var onReviewRecordsReset: (@MainActor () -> Void)?
    /// This Mac has an approved owner key for the Pond with this `SourceKey`; AppDelegate reads
    /// the Keychain record. Report a Problem needs one.
    public var ownerKeyApproved: @MainActor (String, URL?) -> Bool = { _, _ in false }
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
    /// The version each ask's inline review shows, set by Show Changes; memory only. A newer
    /// version arriving during the review never replaces it on its own (`ReviewPage.isStale`).
    @Published public var reviewing: [String: RevisionStamp] = [:]
    /// Asks whose Use Version N is in flight (Touch ID, then the Pond call).
    @Published public internal(set) var accepting: Set<String> = []
    /// Report a Problem's docked composer, by ask: the step path it reports on. Memory only.
    @Published public var reporting: [String: String] = [:]
    /// The composer's send state, by ask, while it isn't idle.
    @Published public internal(set) var reportStates: [String: ReportBoxState] = [:]
    /// A note sent before this Mac had an approved owner key, by ask: held in memory only,
    /// sent once the key is approved (`flushHeldReports`), dropped if the ask closes.
    var heldReports: [String: String] = [:]
    /// The Messages field's text, by ask. Memory only, like `drafts`. Editing a refused draft
    /// clears the refusal.
    @Published public var messageDrafts: [String: String] = [:] {
        didSet {
            for (id, state) in messageStates where state != .sending && oldValue[id] != messageDrafts[id] {
                messageStates[id] = nil
            }
        }
    }
    /// The ask whose Messages field has focus, or is asked to take it (⌘L, Message Session…).
    @Published public var messageFocus: String?
    /// The Messages send state, by ask, while it isn't idle.
    @Published public internal(set) var messageStates: [String: MessageBoxState] = [:]
    /// Tick paths as loaded from TickStore, per ask, with the step source they were loaded
    /// against; dropped when the ask's detail changes, and reloaded when the source differs.
    /// Keyed on the source, not the tree: comparing it is cheap, building the tree hashes every step.
    var tickCache: [String: (source: StepSource, ticks: Set<String>)] = [:]
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
    /// Hook's own update is installing (the status reads "Updating…").
    @Published public internal(set) var updating = false
    /// The last run crashed: the docked bar, until Not Now or a send (Store+Crash).
    @Published public internal(set) var crashOffer: CrashOffer?
    /// Called with the signature once a crash is answered, so it isn't raised again.
    public var onCrashHandled: (@MainActor (String) -> Void)?
    /// The send sheet (Review…), until it is sent or cancelled.
    @Published public internal(set) var crashSheet: CrashSheetModel?
    /// The activity log's last lines for a report; the app reads `HookLog`, tests pass their own.
    public var crashLog: @MainActor () -> [String] = { [] }
    /// GitHub's search for a signature (and the version that crashed); the app sets the real one.
    public var issueSearch: @Sendable (String, String) async -> IssueMatch = { _, _ in .unavailable }
    /// Settings › Privacy's target and whether My Pond is offered, read when the sheet opens.
    public var crashTargets: @MainActor () -> (target: CrashTarget, pondOffered: Bool) = { (.github, false) }
    /// The status bar's profile switcher; AppDelegate sets it on every config apply.
    @Published public internal(set) var profiles = ProfileMenu.empty
    /// The Undo bar as it was when the quit-time sends began; `undoInfo` while they run.
    @Published private var sendingUndo: UndoInfo?
    public var shell = PanelShellActions.none
    /// This Mac's host name (HostName.current), cached: the app sets it at launch and when the
    /// panel becomes key. nil until then, which dims Resume Session.
    @Published public private(set) var localHost: String?
    /// This Mac mode: the queue is this Mac's own.
    public var queueIsLocal: Bool { sourceKey == SourceKey.local }
    /// Publishes only when the name changed.
    public func setLocalHost(_ name: String?) {
        guard localHost != name else { return }
        localHost = name
    }
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

    var source: (any QueueSource)?
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

    // MARK: Review state (Store+Review.swift)

    /// The raw served item per id, as the last list, detail or closed list brought it. Only
    /// the review code reads it: `listed`, `details` and `recentlyClosed` hold rendered copies.
    var served: [String: WireItem] = [:]
    /// Each revised ask's history: the fetched detail's, brought up to date by the list.
    public internal(set) var histories: [String: Result<VerifiedHistory, HistoryProblem>] = [:]
    var fetchedHistories: [String: Result<VerifiedHistory, HistoryProblem>] = [:]
    var listedHistories: [String: Result<VerifiedHistory, HistoryProblem>] = [:]
    /// The last body rendered from a verified revision, for a locked ask whose shown body
    /// isn't at hand (a list item before its detail, or a history that failed).
    var lastRendered: [String: Instructable] = [:]
    /// Every review record, by `ReviewStore.key`, for all sources; authoritative, saved sealed.
    var reviews: [String: ReviewRecord] = [:]
    let reviewFile: ReviewPersistence?
    var sealKey: SymmetricKey?
    /// The Keychain refused the seal key: no records loaded, nothing written, corrected asks locked.
    public internal(set) var reviewsUnreadable = false
    var reviewSaveScheduled = false
    /// A load problem to post once the first swap has cleared the Notice slot.
    var pendingReviewNotice: PanelNotice?
    /// The connected Pond's version (MailboxCheck.pond); nil until checked, and in This Mac mode.
    public internal(set) var pond: PondVersion?
    /// The review state each open ask's Notice was last posted for, so a poll doesn't repost it.
    var reviewNoticed: [String: ReviewState] = [:]

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
                timeoutSleep: (@Sendable (Duration) async -> Void)? = nil,
                reviews: ReviewPersistence? = nil) {
        self.defaults = defaults
        self.reviewFile = reviews
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
        loadReviews()
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
        if let pending = pendingReviewNotice {
            pendingReviewNotice = nil
            notice = pending
        }
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
        served = [:]
        histories = [:]
        fetchedHistories = [:]
        listedHistories = [:]
        lastRendered = [:]
        reviewNoticed = [:]
        pond = nil
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
        listed = fresh.map(ingestListed)
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
        if let selected = navigation.selectedID { noticeReview(selected) }
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
        reviewNoticed[id] = nil
        noticeReview(id)
        loadIfMissing(id)
    }

    public func back() {
        navigation.back()
        notFoundID = nil
    }

    /// The panel came on screen: logs the screen it shows, the queue or an ask.
    public func panelShown() {
        screens.reset()
        logScreen()
    }

    /// `screen queue` or `screen detail`, once per change; never which ask.
    private func logScreen() {
        let screen: HookLog.Screen = navigation.selectedID == nil ? .queue : .detail
        if screens.open(screen) { HookLog.screen(screen) }
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
            holdingQueue {
                details[id] = ingestDetail(detail)
                tickCache[id] = nil
                rerender(id)
            }
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

    /// Ticks key on fingerprints and content hashes only, so their loads pass no events.
    private func stepTree(_ item: WireItem, events: [Event] = []) -> [DetailModel.Node] {
        stepTreeBuilds += 1
        return DetailModel.make(item: item, events: events, history: try? histories[item.id]?.get()).nodes
    }

    /// The answered paths of an ask whose detail is cached; nil without one.
    private func answered(_ id: String) -> Set<String>? {
        guard let events = details[id]?.events else { return nil }
        let key = [events.count, events.last?.seq ?? 0, renderedStamp(id)?.rev ?? 0]
        if let hit = answeredCache[id], hit.key == key { return hit.paths }
        let paths = Set(Answers.current(events: events, history: try? histories[id]?.get(),
                                        rendered: item(for: id)?.instructable).counted.keys)
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
        guard !isContentLocked(id), let nodes = nodes(for: id), let node = Flow.flattened(nodes).first(where: { $0.path == path }) else { return }
        let before = ticks(for: id)
        let after = Flow.toggle(node, ticks: before, locked: Set(Flow.lockedPaths(nodes: nodes, ticks: before)))
        guard after != before else { return }
        HookLog.action(.tick)
        let added = Flow.items(of: nodes).map(\.path).filter { after.contains($0) && !before.contains($0) }
        tickHistory[id, default: []].append(contentsOf: added)
        setTicks(after, for: id, nodes: nodes)
    }

    /// ⌘T: ticks the current item and returns its path (an optional question's too); nil when
    /// every item is done or the current one is a required question.
    @discardableResult public func tickCurrent(in id: String) -> String? {
        guard !isContentLocked(id), let nodes = nodes(for: id) else { return nil }
        let result = Flow.tickCurrent(ticks: ticks(for: id), nodes: nodes)
        guard let path = result.path else { return nil }
        HookLog.action(.tick)
        tickHistory[id, default: []].append(path)
        setTicks(result.ticks, for: id, nodes: nodes)
        return path
    }

    /// ⇧⌘T: unticks the leaf ticked last this session, else the last ticked leaf in order.
    @discardableResult public func untickLast(in id: String) -> String? {
        guard !isContentLocked(id), let nodes = nodes(for: id) else { return nil }
        let ticks = ticks(for: id)
        let result = Flow.untickLast(ticks: ticks, history: tickHistory[id] ?? [], nodes: nodes,
                                     locked: Set(Flow.lockedPaths(nodes: nodes, ticks: ticks)))
        guard let path = result.path else { return nil }
        HookLog.action(.tick)
        tickHistory[id]?.removeAll { $0 == path }
        setTicks(result.ticks, for: id, nodes: nodes)
        return path
    }

    private func setTicks(_ ticks: Set<String>, for id: String, nodes: [DetailModel.Node]) {
        // The detail reads ticks too, and an ask outside the filter changes no queue row.
        objectWillChange.send()
        let leaves = ticks.intersection(Flow.items(of: nodes).map(\.path))
        tickCache[id] = item(for: id).map { (StepSource($0), leaves) }
        TickStore.save(defaults, sourceKey: sourceKey, id: id, ticks: leaves, nodes: nodes)
        clearChips(id, ticked: Set(Flow.items(of: nodes).filter { leaves.contains($0.path) }.compactMap(\.stepID)))
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
        pruneReviews(keep: keep)
        detailRequestedAt = detailRequestedAt.filter { keep.contains($0.key) }
        guard keep != prunedKeep else { return }
        prunedKeep = keep
        TickStore.prune(defaults, sourceKey: sourceKey, keep: keep)
    }

    /// Done or Skip, held 10 s for Undo. In the detail, `afterClose` decides whether
    /// the next ask opens; from the list, the next row is selected.
    /// While the ask is locked for review only Skip goes through: Done is refused here.
    public func close(_ id: String, _ verdict: Verdict) {
        guard source != nil else { return }
        if verdict == .done, isContentLocked(id) { return }
        HookLog.action(verdict == .done ? .done : .skip)
        reviewing[id] = nil
        let order = visibleOrder
        let inDetail = navigation.selectedID == id
        doneWarnings.remove(id)
        pending.add(id: id, verdict: verdict, note: nil, title: item(for: id)?.title ?? "", now: now(),
                    stamp: verdict == .done ? renderedStamp(id) : nil)
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
        HookLog.action(.undo)
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

    public func post(_ notice: PanelNotice) {
        self.notice = notice
        guard notice.isTransient, noticeReset == nil else { return }
        noticeReset = Task { [weak self, sleep] in
            try? await sleep(.seconds(DS.Motion.noticeHold))
            guard !Task.isCancelled, let self, self.notice == notice else { return }
            self.notice = nil
        }
    }

    /// The owner dismissed the Notice (✕) or pressed its button; a newer Notice replacing it doesn't count.
    public var onNoticeCleared: (@MainActor (PanelNotice) -> Void)?

    public func dismissNotice() {
        guard let current = notice else { return }
        notice = nil
        onNoticeCleared?(current)
    }

    /// Back, Esc, Next Ask or opening another ask leaves the closed ask, and its Notice with it.
    private func dropNoticeOfLeftAsk() {
        if notice?.isTransient == true, navigation.selectedID != nil {
            notice = nil
            return
        }
        guard let id = notice?.detailAskID, navigation.selectedID != id else { return }
        notice = nil
        sessionClosedNext = nil
    }

    /// The Notice's button: Retry, Next Ask, Show Closed Ask, Try Again, Show in Finder or Reset Review Records….
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
        case .pondOlder:
            shell.updateMailbox()
        case .hookOlder:
            shell.checkForUpdates()
        case .corrected(let id, _):
            if navigation.selectedID != id { open(id) }
            startReview(id)
        case .historyChanged:
            await trustHistoryAgain()
        case .reviewRecordsUnreadable:
            // Declined, the lock and its Notice stay.
            if !(await resetReviewRecords()), reviewsUnreadable { post(.reviewRecordsUnreadable) }
        case .storeFailed, .settingsReloaded, .updating, .resumeFailed, .mailboxUpToDate, .mailboxUpdateFailed,
             .mailboxUpdateCommandInvalid, .ownerKeyRefused, .reviewRecordsChanged,
             .doneHeldBack, .acceptFailed, .crashReport:
            break
        case .newAgents:
            shell.openSettings(.agents)
        }
        onNoticeCleared?(current)
    }

    /// The Notice's second button: "How to update" opens the mailbox update guide. The
    /// Notice stays, so Update Mailbox… is still there after reading.
    public func performNoticeSecondaryAction() {
        guard case .pondOlder? = notice else { return }
        shell.openURL(MailboxProtocol.updateDocsURL)
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
                    (try? await source.resolve(close.id, verdict: close.verdict, note: close.note, stamp: close.stamp)) != nil
                        ? close.id : nil
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
            reviewing[id] = nil
            quietIDs.insert(id)
            recentlyClosed.removeAll { $0.id == id }
            await freshRefresh()
            guard gen == generation else { return }
            if navigation.selectedID == id { await load(id, from: source, generation: gen) }
            onCloseSent?(id)
            onAnnounce?("Ask reopened")
        } catch {
            guard gen == generation else { return }
            if ownerKeyRefused(error) { return }
            post(.reopenFailed(id: id, title: item(for: id)?.title ?? "", reason: UserFacingError.text(error)))
        }
    }

    /// The last 24 hours of closed asks, and who closed each (from its events).
    /// A failed fetch keeps the previous list.
    private func loadClosed(from source: any QueueSource, generation gen: Int) async {
        guard let fresh = try? await source.recentlyClosed(within: Self.closedWindow) else { return }
        guard gen == generation else { return }
        let open = Set(listed.map(\.id))
        let closed = fresh.filter { !open.contains($0.id) && !pending.contains($0.id) }.map(ingestListed)
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

    func updateItems() {
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
            // A local acceptance the Pond hasn't heard of goes first, or the Done would be refused.
            if close.verdict == .done { try await sendPendingAccept(close.id, via: source) }
            try await withAcceptRecovery(close.id, via: source) {
                _ = try await source.resolve(close.id, verdict: close.verdict, note: close.note, stamp: close.stamp)
            }
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
            if ownerKeyRefused(error) { return }
            post(.actionFailed(verdict: close.verdict, id: close.id, title: close.title, reason: Self.failureReason(error)))
        }
    }

    /// True after posting `.ownerKeyRefused` and telling AppDelegate, for a 403 "unknown owner key".
    func ownerKeyRefused(_ error: any Error) -> Bool {
        guard case QueueError.ownerKeyRefused? = error as? QueueError else { return false }
        post(.ownerKeyRefused)
        onOwnerKeyRefused?()
        return true
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
                    _ = try await old.resolve(close.id, verdict: close.verdict, note: close.note, stamp: close.stamp)
                    await onCloseSent?(close.id)
                } catch {
                    HookLog.error("Store", "a held-back close couldn't be sent before the queue changed: "
                                  + error.localizedDescription)
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
            _ = ownerKeyRefused(error)
            return .failure(error)
        }
    }

    public func sendReply(_ id: String) async -> Bool {
        let text = (drafts[id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, replyStates[id] != .sending, !isContentLocked(id) else { return false }
        return await send(text, for: id) {
            self.drafts[id] = nil
            self.editingReply.remove(id)
        }
    }

    public func sendChoice(_ id: String) async -> Bool {
        guard let index = pendingChoice[id], let choices = item(for: id)?.instructable?.reply?.choices,
              choices.indices.contains(index), replyStates[id] != .sending, !isContentLocked(id) else { return false }
        return await send(ReplyText.wire(choice: choices[index]), for: id) {
            self.pendingChoice[id] = nil
            self.editingReply.remove(id)
        }
    }

    /// Done (the button or ⌘↩, in the detail or the queue): closes when nothing is unsent,
    /// else shows the bar's warning; it never sends or drops an answer silently. From the
    /// queue, the ask opens first so the warning is on screen.
    public func warnUnsent(_ id: String) {
        guard !isContentLocked(id) else { return }
        guard primaryAction(for: id) == .sendAndDone else {
            close(id, .done)
            return
        }
        // Opening first: a navigation change drops the warnings of every other ask.
        if navigation.selectedID != id { open(id) }
        doneWarnings.insert(id)
    }

    /// Esc in the warning: back to editing, with everything kept.
    public func cancelDoneWarning(_ id: String) {
        doneWarnings.remove(id)
    }

    /// Discard & Done: drops the unsent reply text, pick and step answers (and any Change in
    /// progress), then closes. Nothing is sent.
    public func discardAndDone(_ id: String) {
        guard answerStates[id] != .sending, replyStates[id] != .sending, !isContentLocked(id) else { return }
        doneWarnings.remove(id)
        drafts[id] = nil
        pendingChoice[id] = nil
        answerDrafts[id] = nil
        answerStates[id] = nil
        editingReply.remove(id)
        editingAnswers[id] = nil
        close(id, .done)
    }

    /// A warning whose ask has nothing unsent any more goes; a later draft doesn't bring it back.
    private func settleDoneWarnings() {
        guard !doneWarnings.isEmpty else { return }
        let kept = doneWarnings.filter { primaryAction(for: $0) == .sendAndDone }
        if kept != doneWarnings { doneWarnings = kept }
    }

    /// Send & Done in the warning: send first and close only when every send worked.
    /// Order: the step answers, then the reply draft or pick, then Done; the first failure stops it
    /// and leaves the warning up, with the failure in place of its caption.
    public func sendAndDone(_ id: String) async {
        guard !isContentLocked(id) else { return }
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
        guard unsent.count > 0, answerStates[id] != .sending, !isContentLocked(id) else { return false }
        HookLog.action(.answer)
        guard let source else {
            answerStates[id] = .failed(reason: AnswerDrafts.failureText(QueueError.unreachable(Self.noSourceProblem)))
            return false
        }
        let sent = answerDrafts[id] ?? [:]
        answerStates[id] = .sending
        let gen = generation
        do {
            try await sendPendingAccept(id, via: source)
            let stamp = renderedStamp(id)
            try await withAcceptRecovery(id, via: source) {
                _ = try await source.answer(id, answers: unsent.batch, stamp: stamp)
            }
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
            answerStates[id] = .failed(reason: Self.isReviewFailure(error) ? Self.failureReason(error)
                                                                          : AnswerDrafts.failureText(error))
            _ = ownerKeyRefused(error)
            return false
        }
    }

    /// Drops every answer draft that the cached detail shows as sent (from here, or a Telegram tap).
    private func settleAnswerDrafts() {
        guard !answerDrafts.isEmpty else { return }
        var next = answerDrafts
        for (id, drafts) in answerDrafts {
            guard let detail = details[id] else { continue }
            let kept = AnswerDrafts.settled(drafts, nodes: DetailModel.make(
                item: detail.item, events: detail.events, history: try? histories[id]?.get()).nodes)
            next[id] = kept.isEmpty ? nil : kept
        }
        if next != answerDrafts { answerDrafts = next }
    }

    private func send(_ text: String, for id: String, onSuccess: () -> Void) async -> Bool {
        HookLog.action(.reply)
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

    /// Fetches the ask again from the current source.
    func reload(_ id: String) async {
        guard let source else { return }
        await load(id, from: source, generation: generation)
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

    /// Fetched details, as one change; an unchanged detail changes nothing. Each is stored as its
    /// rendered copy, and the ask's list and closed rows are rendered again from its history.
    private func apply(_ fetched: [(id: String, result: DetailFetch)]) {
        holdingQueue { applyDetails(fetched) }
    }

    private func applyDetails(_ fetched: [(id: String, result: DetailFetch)]) {
        var next = details
        var loaded: [String] = []
        for (id, fetch) in fetched {
            switch fetch {
            case .loaded(let raw):
                let detail = ingestDetail(raw)
                loaded.append(id)
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
        loaded.forEach(rerender)
        if let selected = navigation.selectedID, loaded.contains(selected) { noticeReview(selected) }
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

    func queueInputChanged() {
        if queueHolds > 0 {
            queueStale = true
        } else {
            rebuildQueue()
        }
    }

    /// Runs `body` with queue rebuilds held, then rebuilds once if any input changed.
    func holdingQueue(_ body: () -> Void) {
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
            closedBy: { self.closedBy($0) }, review: { self.reviewState($0.id) },
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
        let review = reviewState(id)
        let stamp = ReviewGate.renderedStamp(review, history: try? histories[id]?.get())
        if case .current(let current) = review, details[id] != nil, stamp == current { markSeen(id, current) }
        var snapshot = DetailSnapshot.build(
            item: item, detail: details[id], ticks: ticks(for: id), load: load, reply: replyStates[id] ?? .idle,
            draft: drafts[id], pendingChoice: pendingChoice[id], busy: replyStates[id] == .sending, previous: previous, next: next,
            closedBy: closedBy(item), answerDrafts: answerDrafts[id] ?? [:], answerState: answerStates[id],
            doneWarning: doneWarnings.contains(id), review: review, stamp: stamp,
            history: try? histories[id]?.get(), chips: chips(id, review: review), reported: reported(id),
            addedSinceShown: addedSinceShown(id, review: review))
        snapshot.canMessage = talk.messages
        snapshot.message = messageStates[id] ?? .idle
        snapshot.canReport = canReport(id)
        if snapshot.canReport, let target = reporting[id] {
            snapshot.reportTarget = target
            snapshot.report = reportStates[id] ?? .idle
            // Read only while the composer is open: the check reads the Keychain.
            snapshot.ownerKeyReady = ownerKeyApproved(sourceKey, identity.mailbox?.url)
        }
        return snapshot
    }

    public var status: PanelStatus {
        PanelStatus.make(StatusInputs(
            sourceKey: sourceKey, reachable: reachable, loadedOnce: loadedOnce, problem: listOK ? nil : listProblem,
            configNote: configNote, listenerNote: listenerProblem, away: away, sendingCloses: sendingCloses,
            updating: updating))
    }

    public func keyContext(textFieldFocused: Bool, popoverOpen: Bool, closedHeaderFocused: Bool) -> KeyContext {
        let selected = listSelection.flatMap { item(for: $0) }
        let opened = navigation.selectedID.flatMap { item(for: $0) }
        return KeyContext(
            mode: opened == nil ? .list : .detail, textFieldFocused: textFieldFocused, popoverOpen: popoverOpen,
            undoAvailable: !pending.isEmpty, filterOn: filter != nil,
            selectionOpen: selected.map { $0.status == "open" },
            selectionHasProject: !(selected?.projectId ?? "").isEmpty,
            selectionHasUnsent: selected.map { $0.status == "open" && primaryAction(for: $0.id) == .sendAndDone } ?? false,
            closedHeaderFocused: closedHeaderFocused,
            askOpen: opened.map { $0.status == "open" } ?? true, askHasProject: !(opened?.projectId ?? "").isEmpty,
            choiceCount: opened?.instructable?.reply?.choices?.count ?? 0,
            hasDraftOrPick: opened.map { primaryAction(for: $0.id) == .sendAndDone } ?? false,
            hasUnsentAnswers: opened.map { unsentAnswers(for: $0.id).count > 0 } ?? false,
            doneWarning: opened.map { doneWarnings.contains($0.id) && primaryAction(for: $0.id) == .sendAndDone } ?? false,
            hasReplyPrompt: opened?.instructable?.reply != nil,
            canMessage: opened.map { canMessage($0.id) } ?? false,
            messageFieldFocused: textFieldFocused && opened != nil && messageFocus == opened?.id)
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
        case .done: if let id = target { close(id, .done) }   // KeyMap sends .warnUnsent when anything is unsent
        case .sendAndDone: if let id = target { sendAndDone(id) }
        case .warnUnsent: if let id = target { warnUnsent(id) }
        case .discardAndDone: if let id = target { discardAndDone(id) }
        case .cancelDoneWarning: if let id = navigation.selectedID { cancelDoneWarning(id) }
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
            if let id = navigation.selectedID, let leaf = currentLeaf, let code = leaf.code {
                copyCode(id, stamp: renderedStamp(id), text: Sanitize.copyText(code))
            }
        case .openCurrentURL:
            if let id = navigation.selectedID, let leaf = currentLeaf, let raw = leaf.url, LinkDisplay.isWeb(raw),
               let url = URL(string: raw) {
                openStepURL(id, stamp: renderedStamp(id), url: url)
            }
        case .pickChoice(let index): if let id = target { pendingChoice[id] = index }
        case .sendAnswers: if let id = navigation.selectedID { sendAnswers(id) }
        case .focusMessage: if let id = navigation.selectedID, canMessage(id) { messageFocus = id }
        case .sendMessage: if let id = navigation.selectedID { sendMessage(id, text: messageDrafts[id] ?? "") }
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
    /// Use Version N from the inline review: on success the review ends.
    public func accept(_ id: String, stamp: RevisionStamp) {
        Task {
            if await acceptRevision(id, stamp: stamp), reviewing[id] == stamp { reviewing[id] = nil }
        }
    }
    public func trustHistoryAgain() { Task { await trustHistoryAgain() } }
    public func reportProblem(_ id: String, stepID: String, note: String) {
        Task { _ = await reportProblem(id, stepID: stepID, note: note) }
    }
    public func sendReport(_ id: String, note: String) { Task { _ = await sendReport(id, note: note) } }
    public func sendMessage(_ id: String, text: String) { Task { _ = await sendMessage(id, text: text) } }

    public func copyLink(_ id: String) {
        HookLog.action(.copy)
        shell.copy("relay://i/\(id)")
    }

    public func retryDetail(_ id: String) {
        detailFailed.remove(id)
        detailRequestedAt[id] = now()
        scheduleTimeoutTick()
        guard let source else { return }
        let gen = generation
        Task { await self.load(id, from: source, generation: gen) }
    }
}
