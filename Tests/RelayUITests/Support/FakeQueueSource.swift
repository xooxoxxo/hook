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
    private(set) var calls: [String] = []
    private(set) var replies: [String: [String]] = [:]

    init(items: [WireItem] = [], details: [String: AskDetail] = [:]) {
        self.items = items
        self.details = details
    }

    func setItems(_ items: [WireItem]) { self.items = items }
    func setClosed(_ items: [WireItem]) { closedItems = items }
    func setListDelay(_ delay: Duration) { listDelay = delay }
    func setDetail(_ detail: AskDetail) { details[detail.item.id] = detail }

    /// While held, every `resolve` waits after it is recorded until `releaseResolves()`.
    func holdResolves() { resolvesHeld = true }
    func releaseResolves() {
        resolvesHeld = false
        let waiting = heldResolves
        heldResolves = []
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
        throw QueueError.unreachable("posting isn't faked")
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
        try record("reply \(id)")
        guard let item = (items + closedItems).first(where: { $0.id == id }) else { throw QueueError.notFound }
        var detail = details[id] ?? AskDetail(item: item, events: [])
        detail.events.append(Event(seq: detail.events.count + 1, itemId: id, kind: "reply", actor: "owner",
                                   text: text, at: "2026-10-16T09:40:00+00:00"))
        details[id] = detail
        replies[id, default: []].append(text)
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

    func changes() async -> AsyncStream<Void>? { nil }
}
