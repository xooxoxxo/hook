import Foundation

/// The in-process `LocalQueue` as a `QueueSource`. Relay is the owner here, so
/// resolve, reply and reopen record actor "owner".
///
/// A wrapper rather than `extension LocalQueue: QueueSource`: the protocol's
/// `get` and `reply` would overload LocalQueue's own and hijack its callers.
public struct LocalQueueSource: QueueSource {
    public let queue: LocalQueue

    public init(queue: LocalQueue) {
        self.queue = queue
    }

    public func list() async throws -> [WireItem] {
        await queue.list(status: "open", days: nil).map(\.wireItem)
    }

    public func get(_ id: String) async throws -> AskDetail {
        guard let found = await queue.get(id) else { throw QueueError.notFound }
        return AskDetail(item: found.item.wireItem, events: found.events.map(\.event))
    }

    public func post(project: String, instructable: Data) async throws -> PostResult {
        let value: JSONValue
        do {
            value = try JSONValue.parse(instructable)
        } catch {
            throw QueueError.rejected(status: 400, error: "invalid json", details: [])
        }
        do {
            let result = try await queue.post(project: .string(project), instructable: value)
            return PostResult(item: result.item.wireItem, deduped: result.deduped, openURL: nil)
        } catch let error as LocalQueueError {
            throw error.queueError
        }
    }

    public func resolve(_ id: String, verdict: Verdict, note: String?) async throws -> WireItem {
        do {
            let note: JSONValue? = note.map { .string($0) }
            return try await queue.resolve(id, verdict: verdict.rawValue, actor: "owner", note: note).wireItem
        } catch let error as LocalQueueError {
            throw error.queueError
        }
    }

    public func reply(_ id: String, text: String) async throws -> WireItem {
        do {
            return try await queue.reply(id, text: text).wireItem
        } catch let error as LocalQueueError {
            throw error.queueError
        }
    }

    public func reopen(_ id: String) async throws -> WireItem {
        do {
            return try await queue.reopen(id).wireItem
        } catch let error as LocalQueueError {
            throw error.queueError
        }
    }

    public func recentlyClosed(within interval: TimeInterval) async throws -> [WireItem] {
        await queue.recentlyClosed(within: interval).map(\.wireItem)
    }

    public func changes() async -> AsyncStream<Void>? {
        await queue.subscribe()
    }
}

extension LocalQueueError {
    /// HTTP status, API error string and field-path details.
    var wire: (status: Int, error: String, details: [String]?) {
        switch self {
        case .missingFields: return (400, "missing fields", nil)
        case .invalidInstructable(let details): return (400, "invalid instructable", details)
        case .invalidProject(let details): return (400, "invalid project", details)
        case .invalidNote(let details): return (400, "invalid note", details)
        case .missingText: return (400, "missing text", nil)
        case .textTooLong: return (400, "text too long", nil)
        case .notFound: return (404, "not found", nil)
        case .queueFull: return (429, "queue full", nil)
        case .storeFailed, .locked: return (500, "store failed", nil)
        }
    }

    var queueError: QueueError {
        switch self {
        case .notFound:
            return .notFound
        case .storeFailed(let reason):
            return .storeFailed(reason)
        case .locked:
            return .storeFailed("the queue is locked by another Relay")
        default:
            let wire = self.wire
            return .rejected(status: wire.status, error: wire.error, details: wire.details ?? [])
        }
    }
}
