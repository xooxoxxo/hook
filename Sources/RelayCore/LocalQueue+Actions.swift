import Foundation

extension LocalQueue {
    static let maxReplyScalars = 4000

    /// verdict "done" → status "done"; "declined" → "dismissed". Already finished →
    /// returned unchanged, with no event.
    /// The note is checked like `why` → `.invalidNote`. Unknown id → `.notFound`.
    /// Callers check the verdict first (LocalAPI → 400 `invalid verdict`), so an
    /// unknown verdict here throws `.missingFields`.
    public func resolve(_ id: String, verdict: String, actor: String, note: JSONValue?) throws -> LocalItem {
        let status: String
        switch verdict {
        case "done": status = "done"
        case "declined": status = "dismissed"
        default: throw LocalQueueError.missingFields
        }
        let noteErrors = Validator.validateNote(note)
        guard noteErrors.isEmpty else { throw LocalQueueError.invalidNote(noteErrors) }
        guard let index = state.items.firstIndex(where: { $0.id == id }) else {
            throw LocalQueueError.notFound
        }
        guard state.items[index].status == "open" else { return state.items[index] }

        let text = note?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        let stamp = Timestamp.string(now())
        var next = state
        next.items[index].status = status
        next.items[index].completedAt = stamp
        next.items[index].updated = stamp
        appendEvent(&next, itemId: id, kind: verdict == "done" ? "resolved" : "declined",
                    actor: actor, text: text)
        try commit(next)
        return next.items[index]
    }

    /// The owner takes back a close (app only): status "open", `completedAt` cleared,
    /// and a `reopened` event by the owner. An open ask is returned unchanged, with
    /// no event. Unknown id → `.notFound`.
    public func reopen(_ id: String) throws -> LocalItem {
        guard let index = state.items.firstIndex(where: { $0.id == id }) else {
            throw LocalQueueError.notFound
        }
        guard state.items[index].status != "open" else { return state.items[index] }

        var next = state
        next.items[index].status = "open"
        next.items[index].completedAt = nil
        next.items[index].updated = Timestamp.string(now())
        appendEvent(&next, itemId: id, kind: "reopened", actor: "owner", text: nil)
        try commit(next)
        return next.items[index]
    }

    /// Finished asks (done or dismissed) whose `completedAt` is within `interval`
    /// of now, newest completion first. An ask without a readable `completedAt` is left out.
    public func recentlyClosed(within interval: TimeInterval) -> [LocalItem] {
        let cutoff = now().addingTimeInterval(-interval)
        return state.items.enumerated()
            .compactMap { offset, item -> (offset: Int, completed: Date, item: LocalItem)? in
                guard item.status == "done" || item.status == "dismissed",
                      let completed = item.completedAt.flatMap(Timestamp.date),
                      completed >= cutoff else { return nil }
                return (offset, completed, item)
            }
            .sorted { $0.completed != $1.completed ? $0.completed > $1.completed : $0.offset > $1.offset }
            .map(\.item)
    }

    /// The owner's answer (app only). Trimmed; empty → `.missingText`; more than
    /// 4000 scalars → `.textTooLong`. Works on any existing ask, open or not; the
    /// item itself is unchanged, as on a mailbox.
    public func reply(_ id: String, text: String) throws -> LocalItem {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw LocalQueueError.missingText }
        guard trimmed.unicodeScalars.count <= Self.maxReplyScalars else { throw LocalQueueError.textTooLong }
        guard let item = state.items.first(where: { $0.id == id }) else { throw LocalQueueError.notFound }
        var next = state
        appendEvent(&next, itemId: id, kind: "reply", actor: "owner", text: trimmed)
        try commit(next)
        return item
    }

    /// The owner's answers to step questions (app only), checked by `Answers.validate`
    /// against the stored instructable: unknown id → `.notFound`, then an ask that
    /// isn't open → `.askClosed`, then `.invalidAnswers`. Every answer becomes one
    /// `answer` event by the owner, all in one write; the item itself is unchanged.
    public func answer(_ id: String, answers: JSONValue) throws -> LocalItem {
        guard let item = state.items.first(where: { $0.id == id }) else { throw LocalQueueError.notFound }
        guard item.status == "open" else { throw LocalQueueError.askClosed }
        let texts: [String]
        switch Answers.validate(item.payload.instructable, answers) {
        case .success(let value): texts = value
        case .failure(let failure): throw LocalQueueError.invalidAnswers(failure.errors)
        }
        var next = state
        for text in texts {
            appendEvent(&next, itemId: id, kind: "answer", actor: "owner", text: text)
        }
        try commit(next)
        return item
    }

    /// A NEW stream per call. It yields after every committed mutation; changes
    /// that arrive while the reader is busy collapse into one wake-up. The
    /// continuation is dropped when the reader cancels or the stream is released.
    public func subscribe() -> AsyncStream<Void> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        continuation.onTermination = { [weak self] _ in
            guard let self else { return }
            Task { await self.removeSubscriber(id) }
        }
        subscribers[id] = continuation
        return stream
    }

    func removeSubscriber(_ id: UUID) {
        subscribers[id] = nil
    }
}
