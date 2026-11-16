import Foundation

/// Steps the session added to an open ask since the owner last opened its detail, by ask: the
/// queue card's "+2 steps". Opening the detail clears it; a closed ask drops out. Kept in
/// UserDefaults, so a restart keeps the tag.
public struct UnseenAppends: Sendable, Equatable {
    public static let defaultsKey = "relay.queue.unseenAppends"

    public private(set) var counts: [String: Int]

    public init(counts: [String: Int] = [:]) {
        self.counts = counts.filter { $0.value > 0 }
    }

    /// An append added `steps` top-level steps to `id`.
    public mutating func added(_ id: String, steps: Int) {
        guard steps > 0 else { return }
        counts[id, default: 0] += steps
    }

    /// The owner opened the ask's detail: they see the new steps there.
    public mutating func opened(_ id: String) {
        counts[id] = nil
    }

    /// A closed (or vanished) ask no longer counts. Call only with a loaded list.
    public mutating func keep(open: Set<String>) {
        counts = counts.filter { open.contains($0.key) }
    }

    /// "+1 step", "+2 steps".
    public static func tag(_ count: Int) -> String { count == 1 ? "+1 step" : "+\(count) steps" }

    /// The saved counts; an entry that isn't a whole number is dropped.
    public static func load(_ defaults: UserDefaults) -> UnseenAppends {
        let raw = defaults.dictionary(forKey: defaultsKey) ?? [:]
        return UnseenAppends(counts: raw.compactMapValues { $0 as? Int })
    }

    public func save(_ defaults: UserDefaults) {
        if counts.isEmpty {
            defaults.removeObject(forKey: Self.defaultsKey)
        } else {
            defaults.set(counts, forKey: Self.defaultsKey)
        }
    }
}

/// Which append markers are new since the Store last looked at each ask: the trigger for the
/// card's tag and the one notification. Memory only. The first look at an ask (a first load, a
/// restart, a source swap) is never new.
public struct AppendWatch: Sendable, Equatable {
    /// The newest marker rev seen per ask; 0 when it had none.
    public private(set) var newest: [String: Int] = [:]

    public init() {}

    /// The markers of `id` newer than any seen before; none on the first look.
    public mutating func observe(_ id: String, markers: [AppendMarker]) -> [AppendMarker] {
        let latest = markers.map(\.rev).max() ?? 0
        guard let seen = newest[id] else {
            newest[id] = latest
            return []
        }
        guard latest > seen else { return [] }
        newest[id] = latest
        return markers.filter { $0.rev > seen }
    }

    /// A source swap: every ask is looked at afresh.
    public mutating func forget() { newest = [:] }
}
