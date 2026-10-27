import CryptoKit
import Foundation

/// The local ("This Mac only") queue: the single writer of `queue.json`.
/// Every mutation builds the next state, writes it with the private-file rule, and
/// only then swaps it in and wakes subscribers. A failed write leaves memory unchanged.
public actor LocalQueue {
    public static let maxOpen = 200
    static let dedupeWindow: TimeInterval = 24 * 60 * 60

    let directory: URL
    let now: @Sendable () -> Date
    /// How long `open` keeps trying a lock that reads as taken (see `lock(_:)`).
    let lockWait: TimeInterval
    private(set) var keepDays: Int
    private(set) var state = QueueState.empty()
    /// One continuation per `subscribe()` caller.
    var subscribers: [UUID: AsyncStream<Void>.Continuation] = [:]
    private var lockFD: Int32 = -1

    var fileURL: URL { directory.appending(path: "queue.json") }
    var lockURL: URL { directory.appending(path: "queue.lock") }

    public init(directory: URL, keepDays: Int, now: @escaping @Sendable () -> Date = { Date() },
                lockWait: TimeInterval = LocalQueue.defaultLockWait) {
        self.directory = directory
        self.keepDays = max(1, keepDays)
        self.now = now
        self.lockWait = max(0, lockWait)
    }

    /// Long enough for a spawned child to exec, far shorter than a second Hook would hold it.
    public static let defaultLockWait: TimeInterval = 0.5

    deinit {
        for continuation in subscribers.values { continuation.finish() }
        if lockFD >= 0 { Darwin.close(lockFD) }
    }

    public var epoch: String { state.epoch }

    /// Takes the one-process lock, then loads `queue.json`, moves an unreadable one
    /// aside, or starts a fresh file. Calling it again once open returns `.loaded`.
    public func open() throws -> QueueLoadOutcome {
        if lockFD >= 0 { return .loaded }
        do {
            try PrivateFile.createDirectoryIfMissing(directory)
        } catch {
            throw LocalQueueError.storeFailed("could not create the queue directory: \(error.localizedDescription)")
        }
        // Ownership before the chmod: a folder owned by someone else gets the trust
        // message, not the EPERM that chmod would give.
        do {
            try PrivateFile.checkOwned(directory: directory)
        } catch {
            throw LocalQueueError.storeFailed(error.localizedDescription)
        }
        do {
            try PrivateFile.ensureDirectory(directory)
        } catch {
            throw LocalQueueError.storeFailed("could not create the queue directory: \(error.localizedDescription)")
        }
        do {
            try PrivateFile.checkTrusted(directory: directory)
            try PrivateFile.checkTrusted(file: fileURL)
        } catch {
            throw LocalQueueError.storeFailed(error.localizedDescription)
        }
        let fd = Darwin.open(lockURL.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else {
            throw LocalQueueError.storeFailed("could not open queue.lock (errno \(errno))")
        }
        let code = Self.lock(fd, waitingUpTo: lockWait)
        guard code == 0 else {
            Darwin.close(fd)
            if code == EWOULDBLOCK { throw LocalQueueError.locked }
            throw LocalQueueError.storeFailed("could not lock queue.lock (errno \(code))")
        }
        lockFD = fd
        do {
            return try load()
        } catch {
            close()
            throw error
        }
    }

    /// `flock(LOCK_EX | LOCK_NB)` on `fd`, tried again every 5 ms for up to `wait` seconds
    /// while the lock reads as taken; 0 or the last errno. A flock belongs to the open
    /// file, and a child spawned by any thread of this process (posix_spawn, `Process`)
    /// shares every open file until its exec closes the close-on-exec ones. So for a
    /// moment after `close()` the lock can still be held, by the child, though no queue
    /// holds it: the same folder opened again right then (a test reopening its queue, or
    /// Hook starting while the one it replaces quits) would read as locked. A second Hook
    /// holds the lock for good and still gets `.locked`, after the wait.
    static func lock(_ fd: Int32, waitingUpTo wait: TimeInterval) -> Int32 {
        let deadline = Date().addingTimeInterval(wait)
        while true {
            if flock(fd, LOCK_EX | LOCK_NB) == 0 { return 0 }
            let code = errno
            guard code == EWOULDBLOCK, Date() < deadline else { return code }
            usleep(5_000)
        }
    }

    /// Releases the lock and ends every change stream. The app never calls it (one
    /// queue for the app's lifetime); tests use it to reopen the same directory.
    func close() {
        for continuation in subscribers.values { continuation.finish() }
        subscribers = [:]
        if lockFD >= 0 {
            Darwin.close(lockFD)
            lockFD = -1
        }
    }

    public func post(project: JSONValue?, instructable: JSONValue?) throws -> (item: LocalItem, deduped: Bool) {
        guard let instructable, instructable != .null else { throw LocalQueueError.missingFields }
        let cleaned: JSONValue
        switch Validator.validate(instructable) {
        case .success(let value): cleaned = value
        case .failure(let failure): throw LocalQueueError.invalidInstructable(failure.errors)
        }
        let projectErrors = Validator.validateProject(project)
        guard projectErrors.isEmpty else { throw LocalQueueError.invalidProject(projectErrors) }
        guard let projectName = project?.stringValue, let title = cleaned["title"]?.stringValue else {
            throw LocalQueueError.invalidProject(["project: required"])
        }

        let date = now()
        let key = Self.dedupeKey(project: projectName, title: title)
        let since = date.addingTimeInterval(-Self.dedupeWindow)
        if let existing = state.items.last(where: {
            $0.status == "open" && $0.payload.key == key
                && (Timestamp.date($0.created) ?? .distantPast) > since
        }) {
            return (existing, true)
        }

        let openCount = state.items.reduce(0) { $0 + ($1.status == "open" ? 1 : 0) }
        guard openCount < Self.maxOpen else { throw LocalQueueError.queueFull }

        let item = LocalItem.newAsk(
            id: UUID().uuidString.lowercased(), project: projectName, title: title,
            payload: LocalPayload(why: cleaned["why"]?.stringValue, key: key, instructable: cleaned),
            at: Timestamp.string(date))
        var next = state
        next.items.append(item)
        appendEvent(&next, itemId: item.id, kind: "posted", actor: "session", text: nil)
        try commit(next)
        return (item, false)
    }

    /// `status` is "open", "done", "dismissed" or "all"; `days` nil means any age.
    /// Filters on `created`; newest first, later posts first on equal timestamps.
    public func list(status: String, days: Int?) -> [LocalItem] {
        let cutoff = days.map { now().addingTimeInterval(-Double($0) * 86_400) }
        let picked = state.items.enumerated().compactMap { offset, item -> (offset: Int, created: Date, item: LocalItem)? in
            guard status == "all" || item.status == status else { return nil }
            let created = Timestamp.date(item.created) ?? .distantPast
            if let cutoff, created < cutoff { return nil }
            return (offset, created, item)
        }
        return picked
            .sorted { $0.created != $1.created ? $0.created > $1.created : $0.offset > $1.offset }
            .map(\.item)
    }

    public func get(_ id: String) -> (item: LocalItem, events: [LocalEvent])? {
        guard let item = state.items.first(where: { $0.id == id }) else { return nil }
        return (item, state.events.filter { $0.itemId == id })
    }

    /// Events with `seq > after`, ascending, at most `limit`. `next` is the last
    /// returned seq, or `after` when the page is empty.
    public func events(after: Int, limit: Int) -> (events: [LocalEvent], next: Int) {
        let page = Array(state.events.lazy.filter { $0.seq > after }.prefix(max(0, limit)))
        return (page, page.last?.seq ?? after)
    }

    public func setKeepDays(_ days: Int) {
        keepDays = max(1, days)
        guard lockFD >= 0, let next = Self.pruned(state, keepDays: keepDays, now: now()) else { return }
        try? commit(next)
    }

    // MARK: - Internal, shared with LocalQueue+Actions.swift

    /// Prunes, writes `queue.json` (private-file rule), then swaps the state and
    /// wakes every subscriber. On any error the state is unchanged.
    func commit(_ next: QueueState) throws {
        guard lockFD >= 0 else { throw LocalQueueError.storeFailed("the queue is not open") }
        let final = Self.pruned(next, keepDays: keepDays, now: now()) ?? next
        let data: Data
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            data = try encoder.encode(final)
        } catch {
            // The encoder's message can quote ask content, so it isn't passed on.
            throw LocalQueueError.storeFailed("could not encode the queue")
        }
        do {
            try PrivateFile.write(data, to: fileURL)
        } catch {
            throw LocalQueueError.storeFailed("could not write queue.json: \(error.localizedDescription)")
        }
        state = final
        for continuation in subscribers.values { continuation.yield() }
    }

    func appendEvent(_ s: inout QueueState, itemId: String, kind: String, actor: String, text: String?) {
        s.seq += 1
        s.events.append(LocalEvent(
            seq: s.seq, itemId: itemId, kind: kind, actor: actor, text: text,
            at: Timestamp.string(now())))
    }

    // MARK: - Private

    private func load() throws -> QueueLoadOutcome {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            try commit(QueueState.empty())
            return .fresh
        }
        if let data = try? Data(contentsOf: fileURL),
           let loaded = try? JSONDecoder().decode(QueueState.self, from: data),
           loaded.version == 1 {
            state = loaded
            if let next = Self.pruned(loaded, keepDays: keepDays, now: now()) {
                try commit(next)
            }
            return .loaded
        }
        let moved = try moveAside()
        try commit(QueueState.empty())
        return .recovered(movedTo: moved)
    }

    private func moveAside() throws -> String {
        let base = "queue.json.corrupt-" + Timestamp.fileStamp(now())
        var target = directory.appending(path: base)
        var n = 2
        while FileManager.default.fileExists(atPath: target.path) {
            target = directory.appending(path: "\(base)-\(n)")
            n += 1
        }
        do {
            try FileManager.default.moveItem(at: fileURL, to: target)
        } catch {
            throw LocalQueueError.storeFailed("could not move the unreadable queue.json aside: \(error.localizedDescription)")
        }
        return target.path
    }

    /// First 16 hex characters of SHA-1 over `project + "\n" + title`.
    static func dedupeKey(project: String, title: String) -> String {
        let digest = Insecure.SHA1.hash(data: Data((project + "\n" + title).utf8))
        return String(digest.map { String(format: "%02x", $0) }.joined().prefix(16))
    }

    /// Drops finished asks (and their events) whose `completedAt` is more than
    /// `keepDays` old. Open asks are never removed. Nil when nothing would go.
    static func pruned(_ s: QueueState, keepDays: Int, now: Date) -> QueueState? {
        let cutoff = now.addingTimeInterval(-Double(keepDays) * 86_400)
        var gone = Set<String>()
        for item in s.items where item.status == "done" || item.status == "dismissed" {
            let finished = item.completedAt.flatMap(Timestamp.date) ?? Timestamp.date(item.updated) ?? .distantPast
            if finished < cutoff { gone.insert(item.id) }
        }
        guard !gone.isEmpty else { return nil }
        var next = s
        next.items.removeAll { gone.contains($0.id) }
        next.events.removeAll { gone.contains($0.itemId) }
        return next
    }
}
