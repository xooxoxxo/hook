import Foundation

/// What changed between two polls of `GET /asks?status=open`.
public struct QueueDiff: Sendable, Equatable {
    /// Ids not seen in the previous poll, in the mailbox's order (newest first).
    public var added: [String]
    /// Ids whose `updated` stamp moved.
    public var changed: [String]
    /// Ids that left the open queue (resolved, skipped or removed).
    public var removed: [String]
}

public enum QueueLogic {
    public static func diff(old: [WireItem], new: [WireItem]) -> QueueDiff {
        let before = Dictionary(old.map { ($0.id, $0.updated) }, uniquingKeysWith: { first, _ in first })
        let after = Set(new.map(\.id))
        var added: [String] = []
        var changed: [String] = []
        for item in new {
            if let stamp = before[item.id] {
                if stamp != item.updated { changed.append(item.id) }
            } else {
                added.append(item.id)
            }
        }
        let removed = old.map(\.id).filter { !after.contains($0) }
        return QueueDiff(added: added, changed: changed, removed: removed)
    }

    /// A canonical lowercase uuid, or nil when `raw` is not uuid-shaped.
    public static func normalizedID(_ raw: String) -> String? {
        guard raw.count == 36, let uuid = UUID(uuidString: raw) else { return nil }
        return uuid.uuidString.lowercased()
    }
}
