import Foundation

public enum Verdict: String, Sendable {
    case done
    case declined
}

/// One queue the app shows: the mailbox service, or the local queue.
public protocol QueueSource: Sendable {
    /// Every open ask, whatever its age, newest first.
    func list() async throws -> [WireItem]
    func get(_ id: String) async throws -> AskDetail
    /// `instructable` is the raw JSON object's bytes; the source validates it.
    func post(project: String, instructable: Data) async throws -> PostResult
    /// The app always acts as the owner.
    func resolve(_ id: String, verdict: Verdict, note: String?) async throws -> WireItem
    func reply(_ id: String, text: String) async throws -> WireItem
    /// nil: the Store polls every pollSeconds. Otherwise each call returns a NEW
    /// stream that yields after every committed change, until the caller cancels it.
    func changes() async -> AsyncStream<Void>?
}

extension QueueSource {
    /// Done or Skip without a note.
    public func resolve(_ id: String, verdict: Verdict) async throws -> WireItem {
        try await resolve(id, verdict: verdict, note: nil)
    }
}

/// `POST /asks` → `{item, deduped?, openUrl?}`.
public struct PostResult: Sendable, Decodable, Equatable {
    public let item: WireItem
    public let deduped: Bool
    public let openURL: String?

    enum CodingKeys: String, CodingKey {
        case item, deduped
        case openURL = "openUrl"
    }

    public init(item: WireItem, deduped: Bool, openURL: String?) {
        self.item = item
        self.deduped = deduped
        self.openURL = openURL
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        item = try c.decode(WireItem.self, forKey: .item)
        deduped = try c.decodeIfPresent(Bool.self, forKey: .deduped) ?? false
        openURL = try c.decodeIfPresent(String.self, forKey: .openURL)
    }
}

/// Every failure a source reports. Reasons never carry a token or ask contents.
public enum QueueError: Error, Sendable, Equatable, LocalizedError {
    case unreachable(String)
    case unauthorized
    case notFound
    case rejected(status: Int, error: String, details: [String])
    case storeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unreachable(let reason):
            return reason
        case .unauthorized:
            return "The mailbox rejected the token (check the token file)"
        case .notFound:
            return "not found"
        case .rejected(_, let error, let details):
            return details.isEmpty ? error : error + ": " + details.joined(separator: ", ")
        case .storeFailed(let reason):
            return "Couldn't save the queue: \(reason)"
        }
    }
}
