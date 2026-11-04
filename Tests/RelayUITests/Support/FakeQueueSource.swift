import Foundation
import RelayCore

/// An in-memory QueueSource. Every call is recorded in `calls`; `failNext` makes
/// the next matching call throw once.
actor FakeQueueSource: QueueSource {
    private var items: [WireItem]
    private var details: [String: AskDetail]
    private var closedItems: [WireItem] = []
    private var failures: [(call: String?, error: any Error)] = []
    private var listDelay: Duration = .zero
    private var resolvesHeld = false
    private var heldResolves: [CheckedContinuation<Void, Never>] = []
    private var repliesHeld = false
    private var heldReplies: [CheckedContinuation<Void, Never>] = []
    private(set) var calls: [String] = []
    private(set) var replies: [String: [String]] = [:]
    /// Every answer batch sent, per ask.
    private(set) var answers: [String: [[JSONValue]]] = [:]
    /// The stamp each stamped act carried, in order ("resolve a", "answer a", "accept a").
    private(set) var stamps: [(call: String, stamp: RevisionStamp)] = []
    /// Every problem report sent.
    private(set) var problems: [(id: String, stepID: String, stamp: RevisionStamp, note: String)] = []
    /// Every post's instructable bytes, and every bug's (signature, instructable bytes).
    private(set) var posted: [(project: String, instructable: Data)] = []
    private(set) var bugs: [(project: String, signature: String, instructable: Data)] = []
    /// Every message sent, per ask, verbatim.
    private(set) var messages: [String: [String]] = [:]
    /// Every progress delta sent (Pond 1.3.0), in order.
    private(set) var progresses: [(id: String, tick: [String], untick: [String], stamp: RevisionStamp?)] = []
    /// What `post` answers (nil: posting isn't faked) and what `postBug` answers.
    private var postAnswer: PostResult?
    private var bugAnswer: BugPostResult = .filed(id: "bug-1")

    init(items: [WireItem] = [], details: [String: AskDetail] = [:]) {
        self.items = items
        self.details = details
    }

    func setItems(_ items: [WireItem]) { self.items = items }
    func setClosed(_ items: [WireItem]) { closedItems = items }
    func setListDelay(_ delay: Duration) { listDelay = delay }
    func setDetail(_ detail: AskDetail) { details[detail.item.id] = detail }
    func setPostAnswer(_ answer: PostResult?) { postAnswer = answer }
    func setBugAnswer(_ answer: BugPostResult) { bugAnswer = answer }

    /// While held, every `resolve` waits after it is recorded until `releaseResolves()`.
    func holdResolves() { resolvesHeld = true }
    func releaseResolves() {
        resolvesHeld = false
        let waiting = heldResolves
        heldResolves = []
        waiting.forEach { $0.resume() }
    }

    /// While held, every `reply` waits before it is recorded (so `failNext` still applies) until `releaseReplies()`.
    func holdReplies() { repliesHeld = true }
    var heldReplyCount: Int { heldReplies.count }
    func releaseReplies() {
        repliesHeld = false
        let waiting = heldReplies
        heldReplies = []
        waiting.forEach { $0.resume() }
    }

    /// `call` matches a prefix of the recorded call ("resolve", "reply a"); nil matches any call.
    func failNext(_ error: any Error, on call: String? = nil) { failures.append((call, error)) }

    func count(_ prefix: String) -> Int { calls.filter { $0.hasPrefix(prefix) }.count }

    private func record(_ call: String) throws {
        calls.append(call)
        if let index = failures.firstIndex(where: { $0.call.map(call.hasPrefix) ?? true }) {
            throw failures.remove(at: index).error
        }
    }

    func list() async throws -> [WireItem] {
        try record("list")
        if listDelay > .zero { try? await Task.sleep(for: listDelay) }
        return items
    }

    func get(_ id: String) async throws -> AskDetail {
        try record("get \(id)")
        if let detail = details[id] { return detail }
        if let item = (items + closedItems).first(where: { $0.id == id }) { return AskDetail(item: item, events: []) }
        throw QueueError.notFound
    }

    func post(project: String, instructable: Data) async throws -> PostResult {
        try record("post")
        posted.append((project, instructable))
        guard let postAnswer else { throw QueueError.unreachable("posting isn't faked") }
        return postAnswer
    }

    func postBug(project: String, instructable: Data, signature: String) async throws -> BugPostResult {
        try record("postBug \(signature)")
        bugs.append((project, signature, instructable))
        return bugAnswer
    }

    func resolve(_ id: String, verdict: Verdict, note: String?) async throws -> WireItem {
        try record("resolve \(id) \(verdict.rawValue)")
        if resolvesHeld { await withCheckedContinuation { heldResolves.append($0) } }
        guard let index = items.firstIndex(where: { $0.id == id }) else { throw QueueError.notFound }
        var closed = items.remove(at: index)
        closed.status = verdict == .done ? "done" : "dismissed"
        closed.completedAt = "2026-10-16T09:40:00+00:00"
        closedItems.insert(closed, at: 0)
        return closed
    }

    func reply(_ id: String, text: String) async throws -> WireItem {
        if repliesHeld { await withCheckedContinuation { heldReplies.append($0) } }
        try record("reply \(id)")
        guard let item = (items + closedItems).first(where: { $0.id == id }) else { throw QueueError.notFound }
        var detail = details[id] ?? AskDetail(item: item, events: [])
        detail.events.append(Event(seq: detail.events.count + 1, itemId: id, kind: "reply", actor: "owner",
                                   text: text, at: "2026-10-16T09:40:00+00:00"))
        details[id] = detail
        replies[id, default: []].append(text)
        return item
    }

    /// Records the batch and appends one `answer` event per entry (its compact JSON);
    /// a closed ask throws `.askClosed`. No validation.
    func answer(_ id: String, answers batch: [JSONValue]) async throws -> WireItem {
        try record("answer \(id)")
        if closedItems.contains(where: { $0.id == id }) { throw QueueError.askClosed }
        guard let item = items.first(where: { $0.id == id }) else { throw QueueError.notFound }
        var detail = details[id] ?? AskDetail(item: item, events: [])
        for entry in batch {
            detail.events.append(Event(seq: detail.events.count + 1, itemId: id, kind: "answer", actor: "owner",
                                       text: String(decoding: entry.data(), as: UTF8.self),
                                       at: "2026-10-16T09:40:00+00:00"))
        }
        details[id] = detail
        answers[id, default: []].append(batch)
        return item
    }

    func reopen(_ id: String) async throws -> WireItem {
        try record("reopen \(id)")
        guard let index = closedItems.firstIndex(where: { $0.id == id }) else { throw QueueError.notFound }
        var open = closedItems.remove(at: index)
        open.status = "open"
        open.completedAt = nil
        items.insert(open, at: 0)
        return open
    }

    func recentlyClosed(within interval: TimeInterval) async throws -> [WireItem] { closedItems }

    // Pond 1.1.0: the stamped acts record the rev they were bound to ("resolve a done @2").

    func resolve(_ id: String, verdict: Verdict, note: String?, stamp: RevisionStamp?) async throws -> WireItem {
        if let stamp { stamps.append(("resolve \(id)", stamp)) }
        return try await resolve(id, verdict: verdict, note: note)
    }

    func answer(_ id: String, answers: [JSONValue], stamp: RevisionStamp?) async throws -> WireItem {
        if let stamp { stamps.append(("answer \(id)", stamp)) }
        return try await answer(id, answers: answers)
    }

    func accept(_ id: String, stamp: RevisionStamp) async throws -> WireItem {
        try record("accept \(id) @\(stamp.rev)")
        stamps.append(("accept \(id)", stamp))
        guard let item = (items + closedItems).first(where: { $0.id == id }) else { throw QueueError.notFound }
        return item
    }

    func problem(_ id: String, stepID: String, stamp: RevisionStamp, note: String) async throws -> WireItem {
        try record("problem \(id) \(stepID) @\(stamp.rev)")
        problems.append((id, stepID, stamp, note))
        guard let item = items.first(where: { $0.id == id }) else { throw QueueError.notFound }
        var detail = details[id] ?? AskDetail(item: item, events: [])
        let text = String(decoding: JSONValue.object(["id": .string(stepID), "note": .string(note)]).data(), as: UTF8.self)
        detail.events.append(Event(seq: detail.events.count + 1, itemId: id, kind: "problem", actor: "owner", text: text,
                                   at: "2026-10-16T09:40:00+00:00", rev: stamp.rev, auth: "owner-key"))
        details[id] = detail
        return item
    }

    /// Records the message and appends a `message` event; a closed ask throws 409, as the Pond does.
    func message(_ id: String, text: String) async throws -> WireItem {
        try record("message \(id)")
        guard let item = (items + closedItems).first(where: { $0.id == id }) else { throw QueueError.notFound }
        guard item.status == "open" else {
            throw QueueError.rejected(status: 409, error: "ask is closed", details: [])
        }
        var detail = details[id] ?? AskDetail(item: item, events: [])
        detail.events.append(Event(seq: detail.events.count + 1, itemId: id, kind: "message", actor: "owner", text: text,
                                   at: "2026-10-16T09:40:00+00:00", rev: 1, auth: "token"))
        details[id] = detail
        messages[id, default: []].append(text)
        return item
    }

    /// Records the delta ("progress a"); answers the item unchanged.
    func progress(_ id: String, tick: [String], untick: [String], stamp: RevisionStamp?) async throws -> WireItem {
        try record("progress \(id)")
        progresses.append((id, tick, untick, stamp))
        guard let item = (items + closedItems).first(where: { $0.id == id }) else { throw QueueError.notFound }
        return item
    }

    func changes() async -> AsyncStream<Void>? { nil }
}
