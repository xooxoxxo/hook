import Foundation

/// A Pond feature Hook uses that older Ponds don't have.
public enum MailboxFeature: String, CaseIterable, Sendable, Comparable {
    /// Step `question` and `POST /asks/{id}/answers` (Hook 0.7).
    case answers
    /// The `blocking` and `warning` step keys (Hook 0.9).
    case blocking
    /// The `optional` step key (Hook 0.9.1).
    case optional
    /// The `file` step key and a link's `path` (Hook 0.9.1).
    case fileLinks
    /// Step ids, corrections (amend, accept), problem reports and owner acts with the owner key (Hook 0.10).
    case corrections
    /// `POST /asks` with `kind: "bug"`: a crash report filed once per signature, never on Telegram (Hook 0.12).
    case bugs
    /// Messages to the posting session as a reply kind (Hook 0.12).
    case messages
    /// `required` steps and the ask's `done` list, `POST /asks/{id}/progress` and the owner's
    /// Done refused with 409 `requirements_unmet` while something is left (Hook 0.13).
    case requirements
    /// Messages and problem reports of up to 8000 characters, and problem reports over several
    /// lines (Hook 0.14). Older Ponds keep 1000 and 300, one line.
    case longText

    /// The first Pond version that has the feature: everything up to the old protocol level 4
    /// is in 1.0.0.
    public var minimumPond: SemVer {
        switch self {
        case .answers, .blocking, .optional, .fileLinks: return SemVer(major: 1, minor: 0, patch: 0)
        case .corrections: return SemVer(major: 1, minor: 1, patch: 0)
        case .bugs, .messages: return SemVer(major: 1, minor: 2, patch: 0)
        case .requirements: return SemVer(major: 1, minor: 3, patch: 0)
        case .longText: return SemVer(major: 1, minor: 4, patch: 0)
        }
    }

    /// Past what this Hook needs (`PondCompat.required`): Hook checks each one with
    /// `PondVersion.supports(_:)` and works without it, so the "older Pond" Notice never names it.
    public var gated: Bool {
        switch self {
        case .bugs, .messages, .requirements, .longText: return true
        case .answers, .blocking, .optional, .fileLinks, .corrections: return false
        }
    }

    /// How the Notice names the feature.
    public var displayName: String {
        switch self {
        case .answers: return "per-step answers"
        case .blocking: return "blocking steps"
        case .optional: return "optional steps"
        case .fileLinks: return "file links"
        case .corrections: return "step corrections and the owner key"
        case .bugs: return "crash reports sent to your Pond"
        case .messages: return "messages to sessions"
        case .requirements: return "required steps before Done"
        case .longText: return "long messages and reports"
        }
    }

    /// By Pond version, then in declaration order, so features of one version keep a fixed order.
    public static func < (a: MailboxFeature, b: MailboxFeature) -> Bool {
        if a.minimumPond != b.minimumPond { return a.minimumPond < b.minimumPond }
        let all = allCases
        return all.firstIndex(of: a)! < all.firstIndex(of: b)!
    }
}

/// The Pond's versions (docs/mailbox-protocol.md). A Pond answers `GET /version` with a
/// semver `version` (1.0.0 on), or, before semver, a dated version and a protocol level; one
/// without `/version` is protocol 1. `PondCompat.required` names the range this Hook needs.
public enum MailboxProtocol {
    /// What a Pond without `GET /version` (404) counts as.
    public static let baseline = 1
    /// The update guide that "How to update" and an unset `mailboxUpdateCommand` open.
    public static let updateDocsURL = URL(
        string: "https://github.com/xooxoxxo/hook/blob/main/docs/mailbox-protocol.md#updating-the-mailbox")!

    /// The needed (not gated) features a Pond lacks, by its effective version, in version order. A protocol-4 Pond
    /// (1.0.0) lacks only `corrections`; one below protocol 4 lacks everything (no Pond runs there).
    public static func missingFeatures(pond: PondVersion) -> [MailboxFeature] {
        let version = pond.effective
        return MailboxFeature.allCases.filter { !$0.gated && version < $0.minimumPond }.sorted()
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

/// `GET /version`'s reply: `{"service": "pond", "version": "1.1.0", "protocol": 5}`.
public struct MailboxVersion: Equatable, Sendable, Codable {
    public var service: String?
    /// The server's own version string: semver from Pond 1.0.0 on, dated before; nil for a
    /// Pond without `/version`.
    public var version: String?
    /// `protocol`: kept by Pond 1.x for 0.9.x Hooks; new code reads `version` first.
    public var level: Int?

    enum CodingKeys: String, CodingKey {
        case service, version
        case level = "protocol"
    }

    public init(service: String? = nil, version: String? = nil, level: Int?) {
        self.service = service
        self.version = version
        self.level = level
    }

    /// A Pond that answered 404: no `/version`, so protocol 1.
    public static let legacy = MailboxVersion(level: MailboxProtocol.baseline)

    /// Any object decodes, as relay_semver reads it: `service` and `version` are optional
    /// strings and `protocol` a whole number of 1 or more, else nil (protocol 1).
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        level = c.lenient(Int.self, .level).flatMap { $0 >= 1 ? $0 : nil }
        service = c.lenient(String.self, .service)
        version = c.lenient(String.self, .version)
    }

    /// The Pond's version: semver when `version` is strict, else an old Pond by `protocol`.
    public var pond: PondVersion { .from(version: version, protocol: level) }
}

/// How a Pond's version fits the range this Hook needs.
public enum MailboxCompatibility: Equatable, Sendable {
    /// Within the range, or past it on the same major: nothing to say.
    case ok
    /// The Pond is below the range: these features won't work until it is updated.
    case pondOlder(missing: [MailboxFeature])
    /// The Pond is on a newer major than the range: Hook should update.
    case hookOlder

    public static func evaluate(pond: PondVersion, required: SemverRange = PondCompat.range) -> MailboxCompatibility {
        switch required.fit(pond.effective) {
        case .satisfies, .above: return .ok
        case .below: return .pondOlder(missing: MailboxProtocol.missingFeatures(pond: pond))
        case .newerMajor: return .hookOlder
        }
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

    /// The Pond's version; nil when the check failed.
    public var pond: PondVersion? {
        if case .version(let version) = result { return version.pond }
        return nil
    }

    /// The level the update pre-check compares with a release's `mailbox-protocol` marker:
    /// the `protocol` the Pond sent, 4 for a semver Pond that sent none, else 1.
    public var updaterLevel: Int? {
        guard case .version(let version) = result else { return nil }
        if let level = version.level { return level }
        if case .semver = version.pond { return 4 }
        return MailboxProtocol.baseline
    }

    public var compatibility: MailboxCompatibility? { pond.map { MailboxCompatibility.evaluate(pond: $0) } }
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

    /// "Pond 1.1.0 ✓ (needs ^1.1.0)", "Pond 1.0.0 (needs ^1.1.0)", "Pond 2.0.0 (this Hook needs
    /// ^1.1.0)", "Pond (protocol 4) (needs ^1.1.0)" for an old Pond, or why the check failed.
    public static func line(_ check: MailboxCheck?, checking: Bool,
                            required: String = PondCompat.required) -> MailboxVersionLine {
        guard let check else { return MailboxVersionLine(text: "Not checked yet", state: checking ? .checking : .failed) }
        switch check.result {
        case .failed(let reason):
            return MailboxVersionLine(text: "Couldn't check: " + UserFacingError.text(reason),
                                      state: checking ? .checking : .failed)
        case .version(let version):
            let pond = version.pond
            let name: String
            switch pond {
            case .semver(let v): name = "Pond " + Sanitize.revealLine(v.description)
            case .legacy: name = "Pond (\(pond.display))"
            }
            let range = (try? SemverRange(required)) ?? PondCompat.range
            let text: String, state: State
            switch MailboxCompatibility.evaluate(pond: pond, required: range) {
            case .ok: (text, state) = ("\(name) ✓ (needs \(required))", .ok)
            case .pondOlder: (text, state) = ("\(name) (needs \(required))", .needsUpdate)
            case .hookOlder: (text, state) = ("\(name) (this Hook needs \(required))", .hookOlder)
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

/// The markers in a release's notes: `<!-- hook:pond=<range> -->`, the Pond range the release
/// needs, and `<!-- hook:mailbox-protocol=N -->`, the level 0.9.x updaters read.
public enum ReleaseMarker {
    /// The first `hook:pond=` marker's range; nil when there is none or it doesn't parse (then
    /// the level marker decides).
    public static func pondRange(in body: String) -> SemverRange? {
        let pattern = #"<!--\s*hook:pond\s*=\s*(.*?)\s*-->"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: body, range: NSRange(body.startIndex..., in: body)),
              let range = Range(match.range(at: 1), in: body) else { return nil }
        return try? SemverRange(String(body[range]))
    }

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

/// Before Hook updates itself: does the connected Pond fit what the release needs?
public enum UpdatePreflight {
    public enum Decision: Equatable, Sendable {
        case proceed
        /// The release needs `required` (a range, or "protocol N" from the old marker); the
        /// Pond is `current`.
        case pondBehind(required: String, current: PondVersion)
        /// The release needs `required`, but the version check just failed: the dialog says
        /// so and still lets the update go ahead.
        case pondUnchecked(required: String)
    }

    /// With a `hook:pond` range: a Pond that satisfies it, or is past it (same or newer major),
    /// proceeds, so a minor or patch Pond bump never forces anything; one below it is behind.
    /// A release with only the old level marker compares levels, as 0.9.x did: the Pond's
    /// `protocol` (`pondLevel`), else its version read as a level. This Mac mode passes, and so
    /// does a release without markers. An unread Pond passes too, saying so when `checkFailed`.
    public static func decide(pondRange: SemverRange?, legacyLevel: Int?, source: SourceKind?, pond: PondVersion?,
                              pondLevel: Int? = nil, checkFailed: Bool = false) -> Decision {
        guard source == .mailbox, pondRange != nil || legacyLevel != nil else { return .proceed }
        let required = pondRange?.description ?? "protocol \(legacyLevel ?? 0)"
        guard let pond else { return checkFailed ? .pondUnchecked(required: required) : .proceed }
        if let pondRange {
            return pondRange.fit(pond.effective) == .below ? .pondBehind(required: required, current: pond) : .proceed
        }
        let level = pondLevel ?? Self.level(of: pond)
        return level < (legacyLevel ?? 0) ? .pondBehind(required: required, current: pond) : .proceed
    }

    /// An old marker's level for a Pond: its protocol, or for a semver Pond the level it reports
    /// (1.1.0 reports 5, 1.0.0 is 4, 0.N.0 is N).
    static func level(of pond: PondVersion) -> Int {
        switch pond {
        case .legacy(let level): return level
        case .semver(let v):
            if v >= SemVer(major: 1, minor: 1, patch: 0) { return 5 }
            if v.major >= 1 { return 4 }
            return v.minor
        }
    }

    /// Whether the dialog's first button starts Hook's update (rather than the Pond's).
    public static func firstButtonUpdatesHook(_ decision: Decision) -> Bool {
        if case .pondBehind = decision { return false }
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
        case let .pondBehind(required, current):
            let informative = "Hook \(version) needs Pond \(Sanitize.revealLine(required)). "
                + "Your Pond is \(Sanitize.revealLine(current.display)). Update the Pond first, "
                + "or update Hook now and the Pond later (Update Pond…)."
            return Prompt(message: "Update Hook to \(version)?", informative: informative,
                          buttons: [updateMailboxFirst, updateHookAnyway, "Cancel"])
        case .pondUnchecked(let required):
            return Prompt(message: "Update Hook to \(version)?",
                          informative: "Hook couldn't check your Pond, so it can't tell whether the Pond "
                              + "fits \(Sanitize.revealLine(required)), which Hook \(version) needs. You can update "
                              + "Hook now and the Pond later (Update Pond…).",
                          buttons: [updateHookAnyway, "Cancel"])
        }
    }
}
