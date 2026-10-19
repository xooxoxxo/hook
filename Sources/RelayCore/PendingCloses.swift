import Foundation

/// A Done or Skip that has not been sent yet.
public struct PendingClose: Sendable, Equatable {
    public let id: String
    public let verdict: Verdict
    public let note: String?
    /// For the Undo bar.
    public let title: String
    public let deadline: Date

    public init(id: String, verdict: Verdict, note: String?, title: String, deadline: Date) {
        self.id = id
        self.verdict = verdict
        self.note = note
        self.title = title
        self.deadline = deadline
    }
}

/// Closes held back for `delay` seconds so they can be undone. Pure: the caller
/// passes the time in and sends whatever `due` or `drainAll` hands back.
public struct PendingCloses: Sendable {
    public static let delay: TimeInterval = 10

    /// In the order they were added (a re-add moves to the end).
    private var entries: [PendingClose] = []

    public init() {}

    public var isEmpty: Bool { entries.isEmpty }

    public var count: Int { entries.count }

    /// The most recently added.
    public var latest: PendingClose? { entries.last }

    public func contains(_ id: String) -> Bool {
        entries.contains { $0.id == id }
    }

    /// Adding an id that is already pending replaces it, with a new verdict and deadline.
    public mutating func add(id: String, verdict: Verdict, note: String?, title: String, now: Date) {
        entries.removeAll { $0.id == id }
        entries.append(PendingClose(
            id: id, verdict: verdict, note: note, title: title, deadline: now.addingTimeInterval(Self.delay)))
    }

    /// Removes and returns it.
    public mutating func undo(_ id: String) -> PendingClose? {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return nil }
        return entries.remove(at: index)
    }

    public mutating func undoLatest() -> PendingClose? {
        entries.popLast()
    }

    /// Removes and returns those whose deadline has passed (deadline ≤ now), oldest deadline first.
    public mutating func due(now: Date) -> [PendingClose] {
        let ready = entries.filter { $0.deadline <= now }
        entries.removeAll { $0.deadline <= now }
        return Self.oldestFirst(ready)
    }

    /// For quit: removes and returns all, oldest deadline first.
    public mutating func drainAll() -> [PendingClose] {
        let all = entries
        entries = []
        return Self.oldestFirst(all)
    }

    private static func oldestFirst(_ list: [PendingClose]) -> [PendingClose] {
        list.enumerated()
            .sorted { $0.element.deadline != $1.element.deadline ? $0.element.deadline < $1.element.deadline : $0.offset < $1.offset }
            .map(\.element)
    }
}
