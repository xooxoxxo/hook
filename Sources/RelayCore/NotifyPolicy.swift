import Foundation

/// What one notification says: a single ask, or "N new asks".
public enum NotifyContent: Sendable, Equatable {
    /// `project` is the raw project string, "" when the ask has none; `threadIdentifier` uses it.
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

    /// Asks waiting for a scheduled flush.
    public var pendingCount: Int { pending.count }

    /// The asks these settings would notify about, by urgency toggle.
    public func notifiable(_ items: [WireItem]) -> [WireItem] {
        items.filter { wants($0) }
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
        return .single(id: item.id, project: item.projectId ?? "", title: item.title)
    }
}

extension NotifyContent {
    /// Single: the project as one revealed line, or "Hook" when it has none. Several: "Hook".
    public var title: String {
        switch self {
        case .single(_, let project, _):
            let trimmed = project.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "Hook" : Sanitize.revealLine(project)
        case .many:
            return "Hook"
        }
    }

    public var body: String {
        switch self {
        case .single(_, _, let title): Sanitize.revealLine(title)
        case .many(let count): "\(count) new asks"
        }
    }
}

/// Which delivered or pending notifications to remove: an ask that left the
/// open list, whose close was sent, or that was reopened. New asks keep theirs.
public enum NotificationCleanup {
    public static func ids(previousOpen: Set<String>, currentOpen: Set<String>, sent: [String], reopened: [String]) -> Set<String> {
        previousOpen.subtracting(currentOpen).union(sent).union(reopened)
    }
}

/// macOS notification permission, from `UNAuthorizationStatus`.
public enum NotificationPermission: Equatable, Sendable {
    case authorized, denied, notDetermined

    /// `UNAuthorizationStatus.rawValue`: 0 not determined, 1 denied, 2 authorized,
    /// 3 provisional and 4 ephemeral (both allowed); anything else as not determined.
    public init(_ status: Int) {
        switch status {
        case 1: self = .denied
        case 2, 3, 4: self = .authorized
        default: self = .notDetermined
        }
    }
}

/// When Hook asks for notification permission: never at launch; before the first
/// notification it would post, once, and only while undetermined. Welcome page 2 and
/// Settings ask directly.
public enum NotificationAuth {
    public static func shouldRequest(status: NotificationPermission, requestedBefore: Bool) -> Bool {
        status == .notDetermined && !requestedBefore
    }
}
