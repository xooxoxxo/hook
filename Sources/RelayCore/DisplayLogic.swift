import Foundation

/// What sits on the menu-bar symbol's corner.
public enum MenuBarBadge: Sendable, Equatable {
    case none
    case dot
    case number(Int)   // always 1...9
}

/// What the menu-bar status item shows: a red badge on the symbol
/// while any ask is open (the count when it fits in one digit, else a plain
/// dot), dimming when the source is unreachable, the fainter symbol while the
/// owner is away, and the VoiceOver label.
public struct MenuBarState: Sendable, Equatable {
    public var count: Int
    public var nowCount: Int
    public var reachable: Bool
    public var showCount: Bool
    public var offlineReason: String?
    /// Away mode: the symbol is de-emphasised; the badge is unchanged.
    public var away: Bool
    /// The global shortcut's label ("⌃⌥⌘R"); nil when none is set.
    public var shortcut: String?
    /// When the owner went away, in the locale's short time ("10:22").
    public var awaySince: String?

    public init(
        count: Int = 0,
        nowCount: Int = 0,
        reachable: Bool = true,
        showCount: Bool = true,
        offlineReason: String? = nil,
        away: Bool = false,
        shortcut: String? = nil,
        awaySince: String? = nil
    ) {
        self.count = count
        self.nowCount = nowCount
        self.reachable = reachable
        self.showCount = showCount
        self.offlineReason = offlineReason
        self.away = away
        self.shortcut = shortcut
        self.awaySince = awaySince
    }

    /// `items` is the open list.
    public static func from(
        items: [WireItem], reachable: Bool, showCount: Bool, offlineReason: String?, away: Bool = false
    ) -> MenuBarState {
        MenuBarState(
            count: items.count,
            nowCount: items.filter { $0.urgency == "now" }.count,
            reachable: reachable,
            showCount: showCount,
            offlineReason: offlineReason,
            away: away)
    }

    public var badge: MenuBarBadge {
        if count == 0 { return .none }
        if showCount && (1...9).contains(count) { return .number(count) }
        return .dot
    }

    /// Offline: the symbol and the badge dim.
    public var dimmed: Bool { !reachable }

    /// The symbol looks disabled when offline or away.
    public var symbolDimmed: Bool { dimmed || away }

    public var accessibilityLabel: String {
        var label = "Relay, \(count) waiting"
        if nowCount > 0 { label += ", \(nowCount) now" }
        if !reachable { label += ", offline" }
        if away { label += ", away" }
        return label
    }

    /// Always set: "Relay · 5 waiting, 1 now · ⌃⌥⌘R", "Relay · offline: <reason>",
    /// "Relay · away since 10:22 · 5 waiting". The reason is revealed (one line).
    public var tooltip: String {
        if dimmed {
            return "Relay · offline" + (offlineReason.map { ": " + Sanitize.revealLine($0) } ?? "")
        }
        var waiting = count == 0 ? "nothing waiting" : "\(count) waiting"
        if count > 0, nowCount > 0 { waiting += ", \(nowCount) now" }
        var parts = ["Relay"]
        if away { parts.append("away" + (awaySince.map { " since " + $0 } ?? "")) }
        parts.append(waiting)
        if let shortcut { parts.append(shortcut) }
        return parts.joined(separator: " · ")
    }
}

/// A row's age: "now", "12 min ago", "3 h ago", "2 d ago". Parsed to Date, so the Mac's time zone never matters.
public enum RelativeAge {
    public static func text(created: String, now: Date) -> String {
        guard let date = Timestamp.date(created) else { return "" }
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return "now" }
        if seconds < 3600 { return "\(Int(seconds / 60)) min ago" }
        if seconds < 86400 { return "\(Int(seconds / 3600)) h ago" }
        return "\(Int(seconds / 86400)) d ago"
    }
}

/// How a row in "Recently closed" says when and how the ask was closed:
/// "Done 5 min ago", "Skipped 1 h ago", "Closed by the session 2 h ago".
public enum ClosedLine {
    /// `closedBy` is the actor of the closing event ("owner", "session"), when known.
    public static func text(status: String, closedBy: String?, completedAt: String?, now: Date) -> String {
        let how: String
        if closedBy == "session" {
            how = "Closed by the session"
        } else {
            switch status {
            case "done": how = "Done"
            case "dismissed": how = "Skipped"
            default: how = "Closed"
            }
        }
        guard let stamp = completedAt, let date = Timestamp.date(stamp) else { return how }
        return how + " " + ago(max(0, now.timeIntervalSince(date)))
    }

    static func ago(_ seconds: TimeInterval) -> String {
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(Int(seconds / 60)) min ago" }
        if seconds < 86400 { return "\(Int(seconds / 3600)) h ago" }
        return "\(Int(seconds / 86400)) d ago"
    }
}

/// "10:42": the locale's hour and minute (en_GB "09:05", en_US "9:05 AM").
public enum ClockText {
    public static func time(_ date: Date, locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        date.formatted(Date.FormatStyle(locale: locale, timeZone: timeZone).hour().minute())
    }

    /// "" for a stamp that doesn't parse.
    public static func time(_ stamp: String, locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        Timestamp.date(stamp).map { time($0, locale: locale, timeZone: timeZone) } ?? ""
    }
}

/// The closed detail's action-bar line: "Done by you · 11 Oct, 14:32".
public enum ClosedText {
    public static func detail(status: String, closedBy: String?, closedAt: String?,
                              locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        let who: String
        if closedBy == "session" {
            who = "Closed by the session"
        } else {
            switch status {
            case "done": who = "Done by you"
            case "dismissed": who = "Skipped by you"
            default: return "Closed"
            }
        }
        guard let closedAt, let date = Timestamp.date(closedAt) else { return who }
        // Day and time are joined here, not by one combined style: ICU joins those with
        // " at " on recent macOS, and the design's line is "11 Oct, 14:32".
        let day = date.formatted(Date.FormatStyle(locale: locale, timeZone: timeZone).day().month(.abbreviated))
        return who + " · " + day + ", " + ClockText.time(date, locale: locale, timeZone: timeZone)
    }
}
