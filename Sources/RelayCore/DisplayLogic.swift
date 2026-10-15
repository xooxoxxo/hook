import Foundation

/// What sits on the menu-bar symbol's corner.
public enum MenuBarBadge: Sendable, Equatable {
    case none
    case dot
    case number(Int)   // always 1...9
}

/// What the menu-bar status item shows: a red badge on the symbol
/// while any ask is open (the count when it fits in one digit, else a plain
/// dot), dimming when the source is unreachable, and the VoiceOver label.
public struct MenuBarState: Sendable, Equatable {
    public var count: Int
    public var nowCount: Int
    public var reachable: Bool
    public var showCount: Bool
    public var offlineReason: String?

    public init(
        count: Int = 0,
        nowCount: Int = 0,
        reachable: Bool = true,
        showCount: Bool = true,
        offlineReason: String? = nil
    ) {
        self.count = count
        self.nowCount = nowCount
        self.reachable = reachable
        self.showCount = showCount
        self.offlineReason = offlineReason
    }

    /// `items` is the open list.
    public static func from(items: [WireItem], reachable: Bool, showCount: Bool, offlineReason: String?) -> MenuBarState {
        MenuBarState(
            count: items.count,
            nowCount: items.filter { $0.urgency == "now" }.count,
            reachable: reachable,
            showCount: showCount,
            offlineReason: offlineReason)
    }

    public var badge: MenuBarBadge {
        if count == 0 { return .none }
        if showCount && (1...9).contains(count) { return .number(count) }
        return .dot
    }

    public var dimmed: Bool { !reachable }

    public var accessibilityLabel: String {
        var label = "Relay, \(count) waiting"
        if nowCount > 0 { label += ", \(nowCount) now" }
        if !reachable { label += ", offline" }
        return label
    }

    public var tooltip: String? { dimmed ? offlineReason : nil }
}

/// The two-letter project badge on cards and in the detail header.
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

/// The one-line summary under a card's title.
public enum SubLine {
    public static func text(for item: WireItem) -> String {
        guard let ins = item.instructable else {
            if present(item.payload.cmd) { return "1 step" }
            if present(item.payload.link) { return "Link" }
            return ""
        }
        if let choices = ins.reply?.choices, !choices.isEmpty {
            return "Choose 1 of \(choices.count)"
        }
        if !ins.steps.isEmpty {
            var text = ins.steps.count == 1 ? "1 step" : "\(ins.steps.count) steps"
            var places: [String] = []
            for step in ins.steps {
                guard let place = step.place?.trimmingCharacters(in: .whitespaces),
                      !place.isEmpty, !places.contains(place) else { continue }
                places.append(place)
            }
            if !places.isEmpty {
                text += " · " + places.prefix(2).map(Sanitize.revealLine).joined(separator: ", ")
                if places.count > 2 { text += " +\(places.count - 2)" }
            }
            return text
        }
        return ins.reply != nil ? "Reply" : ""
    }

    private static func present(_ value: String?) -> Bool {
        guard let value else { return false }
        return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// A card's age: "now", "5m", "2h", "3d". Parsed to `Date`, so the Mac's time
/// zone never matters.
public enum RelativeAge {
    public static func text(created: String, now: Date) -> String {
        guard let date = Timestamp.date(created) else { return "" }
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return "now" }
        if seconds < 3600 { return "\(Int(seconds / 60))m" }
        if seconds < 86400 { return "\(Int(seconds / 3600))h" }
        return "\(Int(seconds / 86400))d"
    }
}

/// How a row in "Closed today" says when and how the ask was closed:
/// "Done 5m ago", "Skipped 1h ago", "Closed by the session 2h ago".
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
        if seconds < 3600 { return "\(Int(seconds / 60))m ago" }
        if seconds < 86400 { return "\(Int(seconds / 3600))h ago" }
        return "\(Int(seconds / 86400))d ago"
    }
}
