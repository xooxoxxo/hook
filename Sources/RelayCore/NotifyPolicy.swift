import Foundation

/// What one notification says: a single ask, or "N new asks".
public enum NotifyContent: Sendable, Equatable {
    case single(id: String, project: String, title: String)
    case many(Int)
}

public enum NotifyAction: Sendable, Equatable {
    case none
    case show(NotifyContent)
    /// Call `flush(now:)` at this time.
    case scheduleFlush(at: Date)
}

/// Notification grouping. The first new ask shows at once; asks that
/// arrive within `window` of the last notification wait and fold into one, so at
/// most one notification goes out per window. Pure: the caller owns the clock and
/// the timer.
public struct NotifyPolicy: Sendable {
    private var settings: NotifySettings
    private let window: TimeInterval
    private var lastShown: Date?
    private var pending: [WireItem] = []

    public init(settings: NotifySettings, window: TimeInterval = 3) {
        self.settings = settings
        self.window = window
    }

    /// Queued asks whose urgency is now switched off are dropped.
    public mutating func update(settings: NotifySettings) {
        self.settings = settings
        pending = pending.filter { wants($0) }
    }

    public mutating func add(_ items: [WireItem], now: Date) -> NotifyAction {
        let wanted = items.filter { wants($0) }
        guard !wanted.isEmpty else { return .none }
        if let last = lastShown, !pending.isEmpty {
            // A flush is already scheduled; join it (or flush now if its time has passed).
            pending += wanted
            return now >= last + window ? flush(now: now) : .none
        }
        if let last = lastShown, now < last + window {
            pending = wanted
            return .scheduleFlush(at: last + window)
        }
        lastShown = now
        return .show(Self.content(wanted))
    }

    public mutating func flush(now: Date) -> NotifyAction {
        guard !pending.isEmpty, let last = lastShown else { return .none }
        let due = last + window
        guard now >= due else { return .scheduleFlush(at: due) }
        let content = Self.content(pending)
        pending = []
        lastShown = now
        return .show(content)
    }

    /// The ask the sidebar slides in for: the first "now" ask, when `slideIn` is on.
    public func slideInTarget(_ items: [WireItem]) -> WireItem? {
        guard settings.slideIn else { return nil }
        return items.first { $0.urgency == "now" }
    }

    /// Unknown urgencies count as "today", like legacy asks.
    private func wants(_ item: WireItem) -> Bool {
        switch item.urgency {
        case "now": return settings.now
        case "whenever": return settings.whenever
        default: return settings.today
        }
    }

    private static func content(_ items: [WireItem]) -> NotifyContent {
        guard items.count == 1, let item = items.first else { return .many(items.count) }
        return .single(id: item.id, project: item.projectId ?? "Relay", title: item.title)
    }
}
