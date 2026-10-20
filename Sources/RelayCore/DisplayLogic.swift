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

/// The two-letter project badge on a queue card.
public enum Monogram {
    public static let paletteCount = 8

    public static func letters(_ project: String) -> String {
        var words: [String] = []
        var current = ""
        for character in project {
            if character.isLetter || character.isNumber {
                current.append(character)
            } else if !current.isEmpty {
                words.append(current)
                current = ""
            }
        }
        if !current.isEmpty { words.append(current) }
        switch words.count {
        case 0:
            return "?"
        case 1:
            return String(words[0].prefix(2)).uppercased()
        default:
            return (String(words[0].prefix(1)) + String(words[1].prefix(1))).uppercased()
        }
    }

    /// Stable across launches and machines, unlike `hashValue`.
    public static func colorIndex(_ project: String) -> Int {
        Int(fnv1a32(Array(project.lowercased().utf8)) % UInt32(paletteCount))
    }

    public static func fnv1a32(_ bytes: [UInt8]) -> UInt32 {
        var hash: UInt32 = 2_166_136_261
        for byte in bytes {
            hash ^= UInt32(byte)
            hash = hash &* 16_777_619
        }
        return hash
    }
}

/// The one-line summary under a card's title: "Choose 1 of 3", "7 steps · Terminal, Safari",
/// "Reply", "1 step" or "Link"; once a leaf is ticked, the progress "2 of 7". Steps count
/// leaves (a step's sub-steps, then verify), as the progress does.
public enum SubLine {
    public static func text(for item: WireItem, ticked: Set<String> = []) -> String {
        let ins = item.instructable
        return text(QueueLayout.summary(for: item, ticked: ticked),
                    choices: ins?.reply?.choices?.count ?? 0, places: ins.map(places) ?? [])
    }

    /// `choices` is the reply's choice count; `places` the steps' distinct `where`s, in order.
    public static func text(_ summary: RowSummary, choices: Int = 0, places: [String] = []) -> String {
        guard case let .steps(done, total) = summary else { return summary.text }
        if done > 0 { return summary.text }
        if choices > 0 { return RowSummary.choose(choices).text }
        var text = total == 1 ? "1 step" : "\(total) steps"
        if !places.isEmpty {
            text += " · " + places.prefix(2).map(Sanitize.revealLine).joined(separator: ", ")
            if places.count > 2 { text += " +\(places.count - 2)" }
        }
        return text
    }

    /// Each step's `where`, then its sub-steps', trimmed, blank and repeated ones left out.
    public static func places(_ instructable: Instructable) -> [String] {
        var out: [String] = []
        for step in instructable.steps {
            for place in [step.place] + (step.substeps ?? []).map(\.place) {
                guard let place = place?.trimmingCharacters(in: .whitespaces), !place.isEmpty,
                      !out.contains(place) else { continue }
                out.append(place)
            }
        }
        return out
    }
}

/// A row's age: "now", "12 min ago", "3 h ago", "2 d ago". Parsed to Date, so the Mac's time zone never matters.
public enum RelativeAge {
    public static func text(created: String, now: Date) -> String {
        text(created: Timestamp.date(created), now: now)
    }

    /// The same age for a queue card's top row: "now", "12m", "3h", "2d". VoiceOver keeps `text`.
    public static func compact(created: String, now: Date) -> String {
        compact(created: Timestamp.date(created), now: now)
    }

    /// From a stamp parsed already; "" when it didn't parse.
    public static func text(created: Date?, now: Date) -> String {
        format(created: created, now: now, minutes: " min ago", hours: " h ago", days: " d ago")
    }

    public static func compact(created: Date?, now: Date) -> String {
        format(created: created, now: now, minutes: "m", hours: "h", days: "d")
    }

    private static func format(created: Date?, now: Date, minutes: String, hours: String, days: String) -> String {
        guard let date = created else { return "" }
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return "now" }
        if seconds < 3600 { return "\(Int(seconds / 60))" + minutes }
        if seconds < 86400 { return "\(Int(seconds / 3600))" + hours }
        return "\(Int(seconds / 86400))" + days
    }
}

/// How a row in "Recently closed" says when and how the ask was closed:
/// "Done 5 min ago", "Skipped 1 h ago", "Closed by the session 2 h ago".
public enum ClosedLine {
    /// `closedBy` is the actor of the closing event ("owner", "session"), when known.
    public static func text(status: String, closedBy: String?, completedAt: String?, now: Date) -> String {
        text(status: status, closedBy: closedBy, completed: completedAt.flatMap(Timestamp.date), now: now)
    }

    /// From a stamp parsed already; nil leaves the time out.
    public static func text(status: String, closedBy: String?, completed: Date?, now: Date) -> String {
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
        guard let date = completed else { return how }
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
