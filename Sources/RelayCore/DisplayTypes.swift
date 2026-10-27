import Foundation

/// An ask's urgency as the panel shows it. Unknown strings are kept, so the
/// row can show them (revealed) instead of guessing.
public enum Urgency: Equatable, Hashable, Sendable {
    case now, today, whenever
    case unknown(String)

    public init(raw: String?) {
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            self = .today
            return
        }
        switch raw {
        case "now": self = .now
        case "today": self = .today
        case "whenever": self = .whenever
        default: self = .unknown(raw)
        }
    }

    /// Row order inside a project: now, then today (unknown counts as today), then whenever.
    public var rank: Int {
        switch self {
        case .now: return 0
        case .today, .unknown: return 1
        case .whenever: return 2
        }
    }

    /// Raw for an unknown urgency; the view passes it through `revealLine`.
    public var word: String {
        switch self {
        case .now: return "Now"
        case .today: return "Today"
        case .whenever: return "Whenever"
        case .unknown(let raw): return raw
        }
    }
}

/// How the queue is sectioned (`relay.queue.grouping`).
public enum QueueGrouping: String, CaseIterable, Sendable {
    case project, urgency

    public init(stored: String?) {
        self = stored == QueueGrouping.urgency.rawValue ? .urgency : .project
    }
}

/// The trailing text of an open row.
public enum RowSummary: Equatable, Sendable {
    case steps(done: Int, total: Int), choose(Int), reply, legacyCmd, legacyLink, none

    public var text: String {
        switch self {
        case let .steps(done, total): return "\(done) of \(total)"
        case let .choose(count): return "Choose 1 of \(count)"
        case .reply: return "Reply"
        case .legacyCmd: return "1 step"
        case .legacyLink: return "Link"
        case .none: return ""
        }
    }

    /// The small progress bar shows once a leaf is ticked.
    public var showsProgress: Bool {
        if case let .steps(done, _) = self { return done > 0 }
        return false
    }
}

public enum StepState: Equatable, Sendable { case todo, current, done }

/// Where a node sits in the step tree.
public enum StepLevel: Equatable, Hashable, Sendable {
    /// A top-level step, 1-based.
    case top(Int)
    /// A sub-step: the parent's 1-based number and the sub-step's 0-based index.
    case sub(Int, Int)
    case verify

    /// Sub-step letters; an instructable allows at most 10 sub-steps.
    public static let letters: [String] = ["a", "b", "c", "d", "e", "f", "g", "h", "i", "j"]

    public var label: String {
        switch self {
        case .top(let number): return "\(number)"
        case let .sub(number, index): return "\(number)" + Self.letters[index]
        case .verify: return "Verify"
        }
    }

    public var isSub: Bool {
        if case .sub = self { return true }
        return false
    }
}

/// One step's displayable fields, raw; views sanitize each one.
public struct StepContent: Equatable, Sendable {
    public var action: String
    public var place: String?
    public var detail: String?
    public var url: String?
    public var code: String?
    public var lang: String?
    public var expect: String?

    public init(action: String, place: String? = nil, detail: String? = nil, url: String? = nil,
                code: String? = nil, lang: String? = nil, expect: String? = nil) {
        self.action = action
        self.place = place
        self.detail = detail
        self.url = url
        self.code = code
        self.lang = lang
        self.expect = expect
    }
}

public enum StatusSymbol: Equatable, Sendable { case ok, down, connecting, notSetUp, away }

public enum NoticeKind: Equatable, Sendable { case error, info }

/// The detail's prominent button.
public enum PrimaryAction: Equatable, Sendable {
    case done, sendAndDone

    public var title: String {
        switch self {
        case .done: return "Done"
        case .sendAndDone: return "Send & Done"
        }
    }
}

/// What ⌘↑ / ⌘↓ reach from the open ask.
public enum Neighbour: Equatable, Sendable { case ask(String), end, outsideFilter }

/// Open asks hidden by the project filter, and how many of them are "now".
public struct HiddenCount: Equatable, Sendable {
    public var total: Int
    public var now: Int

    public init(total: Int, now: Int) {
        self.total = total
        self.now = now
    }

    public static let zero = HiddenCount(total: 0, now: 0)
}

/// One project in the QueueMenu: the raw name and its open count.
public struct MenuProject: Equatable, Sendable, Identifiable {
    public var name: String
    public var open: Int
    public var id: String { name }

    public init(name: String, open: Int) {
        self.name = name
        self.open = open
    }
}

/// The latest held close, for the Undo bar.
public struct UndoInfo: Equatable, Sendable {
    public var verdict: Verdict
    public var title: String
    public var deadline: Date
    /// Other closes held at the same time ("+N more").
    public var more: Int

    public init(verdict: Verdict, title: String, deadline: Date, more: Int) {
        self.verdict = verdict
        self.title = title
        self.deadline = deadline
        self.more = more
    }
}

public struct ClosedInfo: Equatable, Sendable {
    public var status: String
    public var closedBy: String?
    public var completedAt: String? { didSet { completedDate = completedAt.flatMap(Timestamp.date) } }
    /// `completedAt` parsed, once.
    public private(set) var completedDate: Date?

    public init(status: String, closedBy: String?, completedAt: String?) {
        self.status = status
        self.closedBy = closedBy
        self.completedAt = completedAt
        completedDate = completedAt.flatMap(Timestamp.date)
    }
}

/// One list row, raw strings; AskRow sanitizes.
public struct AskRowModel: Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    /// The raw project string; "" when the ask has none.
    public var project: String
    public var urgency: Urgency
    public var created: String { didSet { createdDate = Timestamp.date(created) } }
    /// `created` parsed, once: the queue's ages read it on every render.
    public private(set) var createdDate: Date?
    public var summary: RowSummary
    /// The card's line under the title (`SubLine`).
    public var subline: String
    public var hasDraft: Bool
    public var closed: ClosedInfo?
    public var resumeCommand: String?
    /// Where the ask came from; Resume Session reads its folder, session and host.
    public var origin: AskOrigin?

    public var isOpen: Bool { closed == nil }

    public init(id: String, title: String, project: String, urgency: Urgency, created: String,
                summary: RowSummary, subline: String? = nil, hasDraft: Bool = false, closed: ClosedInfo? = nil,
                resumeCommand: String? = nil, origin: AskOrigin? = nil) {
        self.id = id
        self.title = title
        self.project = project
        self.urgency = urgency
        self.created = created
        createdDate = Timestamp.date(created)
        self.summary = summary
        self.subline = subline ?? SubLine.text(summary)
        self.hasDraft = hasDraft
        self.closed = closed
        self.resumeCommand = resumeCommand
        self.origin = origin
    }
}

/// One owner reply in "Your replies". `text` is display-ready ("You chose: X"
/// is already revealed); free text is raw and RepliesList runs `prose()` on it.
public struct ReplyLine: Equatable, Sendable, Identifiable {
    /// The event's `seq`.
    public var id: Int
    public var text: String
    /// Local short time, "10:42".
    public var time: String

    public init(id: Int, text: String, time: String) {
        self.id = id
        self.text = text
        self.time = time
    }
}

/// Settings tabs, saved by identifier in `relay.settings.tabID`.
public enum SettingsTabID: String, CaseIterable, Sendable { case general, panel, queue, notifications, connect }
