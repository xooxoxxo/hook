import Foundation

/// A mailbox feature Hook uses that older mailboxes don't have.
public enum MailboxFeature: String, CaseIterable, Sendable, Comparable {
    /// Step `question` and `POST /asks/{id}/answers` (Hook 0.7).
    case answers
    /// The `blocking` and `warning` step keys (Hook 0.9).
    case blocking
    /// The `optional` step key (Hook 0.9.1).
    case optional
    /// The `file` step key and a link's `path` (Hook 0.9.1).
    case fileLinks

    /// The lowest mailbox protocol level that has the feature.
    public var minimumLevel: Int {
        switch self {
        case .answers: return 2
        case .blocking: return 3
        case .optional, .fileLinks: return 4
        }
    }

    /// How the Notice names the feature.
    public var displayName: String {
        switch self {
        case .answers: return "per-step answers"
        case .blocking: return "blocking steps"
        case .optional: return "optional steps"
        case .fileLinks: return "file links"
        }
    }

    /// By level, then in declaration order, so features of one level keep a fixed order.
    public static func < (a: MailboxFeature, b: MailboxFeature) -> Bool {
        if a.minimumLevel != b.minimumLevel { return a.minimumLevel < b.minimumLevel }
        let all = allCases
        return all.firstIndex(of: a)! < all.firstIndex(of: b)!
    }
}

/// The mailbox protocol levels (docs/mailbox-protocol.md). A mailbox answers
/// `GET /version` with its level; one without `/version` is level 1.
public enum MailboxProtocol {
    /// The level this Hook speaks, and the one This Mac's LocalAPI answers with.
    public static let current = 4
    /// What a mailbox without `GET /version` (404) counts as.
    public static let baseline = 1
    /// The update guide that "How to update" and an unset `mailboxUpdateCommand` open.
    public static let updateDocsURL = URL(
        string: "https://github.com/xooxoxxo/hook/blob/main/docs/mailbox-protocol.md#updating-the-mailbox")!

    /// The features a mailbox at `level` lacks, in level order.
    public static func missingFeatures(level: Int) -> [MailboxFeature] {
        MailboxFeature.allCases.filter { $0.minimumLevel > level }.sorted()
    }

    /// "per-step answers", "per-step answers and blocking steps", …
    public static func featureList(_ features: [MailboxFeature]) -> String {
        let names = features.sorted().map(\.displayName)
        switch names.count {
        case 0: return ""
        case 1: return names[0]
        default: return names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
        }
    }
}

/// `GET /version`'s reply: `{"service": "mailbox", "version": "<string>", "protocol": <int>}`.
public struct MailboxVersion: Equatable, Sendable, Codable {
    public var service: String?
    /// The server's own version string; nil for a mailbox without `/version`.
    public var version: String?
    public var level: Int

    enum CodingKeys: String, CodingKey {
        case service, version
        case level = "protocol"
    }

    public init(service: String? = nil, version: String? = nil, level: Int) {
        self.service = service
        self.version = version
        self.level = level
    }

    /// A mailbox that answered 404: no `/version`, so level 1.
    public static let legacy = MailboxVersion(level: MailboxProtocol.baseline)

    /// `protocol` must be a whole number of 1 or more; `service` and `version` are optional strings.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let level = try c.decode(Int.self, forKey: .level)
        guard level >= 1 else {
            throw DecodingError.dataCorruptedError(forKey: .level, in: c, debugDescription: "protocol must be 1 or more")
        }
        self.level = level
        service = c.lenient(String.self, .service)
        version = c.lenient(String.self, .version)
    }
}

/// How a mailbox's level compares with this Hook's.
public enum MailboxCompatibility: Equatable, Sendable {
    case ok
    /// The mailbox is behind: these features won't work until it is updated.
    case mailboxOlder(missing: [MailboxFeature])
    /// The mailbox speaks a level this Hook doesn't know: Hook should update.
    case mailboxNewer

    public static func evaluate(level: Int, hookLevel: Int = MailboxProtocol.current) -> MailboxCompatibility {
        if level > hookLevel { return .mailboxNewer }
        let missing = MailboxProtocol.missingFeatures(level: level).filter { $0.minimumLevel <= hookLevel }
        return missing.isEmpty ? .ok : .mailboxOlder(missing: missing)
    }

    public var isOK: Bool { self == .ok }
}

/// The last version check of the connected source.
public struct MailboxCheck: Equatable, Sendable {
    /// The source it was checked for (`SourceKey`).
    public var sourceKey: String
    public var result: Result
    public var checkedAt: Date

    public enum Result: Equatable, Sendable {
        case version(MailboxVersion)
        /// The check failed (unreachable, refused token, a bad reply).
        case failed(reason: String)
    }

    public init(sourceKey: String, result: Result, checkedAt: Date) {
        self.sourceKey = sourceKey
        self.result = result
        self.checkedAt = checkedAt
    }

    public var level: Int? {
        if case .version(let version) = result { return version.level }
        return nil
    }

    public var compatibility: MailboxCompatibility? { level.map { MailboxCompatibility.evaluate(level: $0) } }
}

/// When the app reads the mailbox's version: on connect, when the source changes, then at
/// most every 30 minutes while it is reachable.
public enum MailboxCheckSchedule {
    public static let interval: TimeInterval = 30 * 60
    /// After Update Mailbox…: how often the run's done file is looked for, and for how long.
    public static let doneFilePoll: TimeInterval = 5
    public static let updateWatchLimit: TimeInterval = 30 * 60
    /// …and the version read every 30 s for the first 10 minutes, in case the window is left open.
    public static let updatePollInterval: TimeInterval = 30
    public static let updatePollLimit: TimeInterval = 10 * 60

    /// `last` is the previous check (any source); `becameReachable` is true on the first
    /// good list after the source was unreachable or new.
    public static func isDue(last: MailboxCheck?, sourceKey: String, reachable: Bool, becameReachable: Bool,
                             now: Date) -> Bool {
        guard sourceKey.hasPrefix("mailbox:"), reachable else { return false }
        guard let last, last.sourceKey == sourceKey else { return true }
        if becameReachable { return true }
        return now.timeIntervalSince(last.checkedAt) >= interval
    }
}

/// Settings › Queue › Connection's Mailbox row.
public struct MailboxVersionLine: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case checking, ok, needsUpdate, hookOlder, failed
    }

    public var text: String
    public var state: State

    public init(text: String, state: State) {
        self.text = text
        self.state = state
    }

    /// "0.9.1 · level 4", "level 1" (a mailbox without `/version`), or why the check failed.
    public static func line(_ check: MailboxCheck?, checking: Bool) -> MailboxVersionLine {
        guard let check else { return MailboxVersionLine(text: "Not checked yet", state: checking ? .checking : .failed) }
        switch check.result {
        case .failed(let reason):
            return MailboxVersionLine(text: "Couldn't check: " + UserFacingError.text(reason),
                                      state: checking ? .checking : .failed)
        case .version(let version):
            let level = "level \(version.level)"
            let text = version.version.map { Sanitize.revealLine($0) + " · " + level } ?? level
            let state: State
            switch MailboxCompatibility.evaluate(level: version.level) {
            case .ok: state = .ok
            case .mailboxOlder: state = .needsUpdate
            case .mailboxNewer: state = .hookOlder
            }
            return MailboxVersionLine(text: text, state: checking ? .checking : state)
        }
    }

    /// The trailing word after the version: ✓ is drawn by the view for `.ok`.
    public var badge: String? {
        switch state {
        case .needsUpdate: return "Needs an update"
        case .hookOlder: return "Newer than Hook"
        case .checking, .ok, .failed: return nil
        }
    }
}

/// The `<!-- hook:mailbox-protocol=N -->` marker in a release's notes: "this Hook needs mailbox level N".
public enum ReleaseMarker {
    /// The first well-formed marker's level; nil when there is none.
    public static func mailboxLevel(in body: String) -> Int? {
        let pattern = #"<!--\s*hook:mailbox-protocol\s*=\s*([0-9]{1,4})\s*-->"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: body, range: NSRange(body.startIndex..., in: body)),
              let range = Range(match.range(at: 1), in: body), let level = Int(body[range]), level >= 1 else {
            return nil
        }
        return level
    }
}

/// Before Hook updates itself: is the connected mailbox new enough for the release?
public enum UpdatePreflight {
    public enum Decision: Equatable, Sendable {
        case proceed
        /// The release needs `required`; the mailbox is at `current`.
        case mailboxBehind(required: Int, current: Int)
        /// The release needs `required`, but the version check just failed: the dialog says
        /// so and still lets the update go ahead.
        case mailboxUnchecked(required: Int)
    }

    /// This Mac mode always passes, and so does a release without a marker. A mailbox whose
    /// level is unknown passes too, saying so when `checkFailed` (the check before the dialog
    /// failed): Hook can't tell.
    public static func decide(required: Int?, source: SourceKind?, mailboxLevel: Int?,
                              checkFailed: Bool = false) -> Decision {
        guard source == .mailbox, let required else { return .proceed }
        guard let mailboxLevel else { return checkFailed ? .mailboxUnchecked(required: required) : .proceed }
        return mailboxLevel < required ? .mailboxBehind(required: required, current: mailboxLevel) : .proceed
    }

    /// Whether the dialog's first button starts Hook's update (rather than the mailbox's).
    public static func firstButtonUpdatesHook(_ decision: Decision) -> Bool {
        if case .mailboxBehind = decision { return false }
        return true
    }

    /// One update confirmation at a time: repeat clicks on Update while the mailbox check
    /// runs or the dialog is open are ignored until it closes.
    public struct ConfirmGate: Sendable {
        public private(set) var isOpen = false
        public init() {}

        /// True when no confirmation is in flight; it is then in flight until `end()`.
        public mutating func begin() -> Bool {
            guard !isOpen else { return false }
            isOpen = true
            return true
        }

        public mutating func end() { isOpen = false }
    }

    /// The update confirmation's texts and buttons, first button default.
    public struct Prompt: Equatable, Sendable {
        public var message: String
        public var informative: String
        public var buttons: [String]
    }

    public static let updateMailboxFirst = "Update Pond First"
    public static let updateHookAnyway = "Update Hook Anyway"

    public static func prompt(version: String, decision: Decision) -> Prompt {
        let version = Sanitize.revealLine(version)
        switch decision {
        case .proceed:
            return Prompt(message: "Update Hook to \(version)?",
                          informative: "Hook rebuilds from your checkout and restarts in about 2 minutes.",
                          buttons: ["Update", "Cancel"])
        case let .mailboxBehind(required, current):
            let missing = MailboxProtocol.missingFeatures(level: current).filter { $0.minimumLevel <= required }
            var informative = "Hook \(version) needs Pond level \(required); yours is \(current)."
            if !missing.isEmpty {
                informative += " Until the Pond is updated, \(MailboxProtocol.featureList(missing)) won't work."
            }
            return Prompt(message: "Update Hook to \(version)?", informative: informative,
                          buttons: [updateMailboxFirst, updateHookAnyway, "Cancel"])
        case .mailboxUnchecked(let required):
            return Prompt(message: "Update Hook to \(version)?",
                          informative: "Hook couldn't check your Pond, so it can't tell whether the Pond "
                              + "has level \(required), which Hook \(version) needs. You can update Hook now and "
                              + "the Pond later (Update Pond…).",
                          buttons: [updateHookAnyway, "Cancel"])
        }
    }
}
