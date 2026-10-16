import Foundation

/// `presence` in config.json: Automatic follows the Mac's signals; Home and
/// Away are set by the owner.
public enum PresenceMode: String, CaseIterable, Sendable {
    case auto
    case home
    case away
}

/// Whether the owner is at the Mac.
public enum PresenceState: String, Sendable {
    case home
    case away
}

/// What the Mac reports, read by `PresenceMonitor`.
public struct PresenceSignals: Sendable, Equatable {
    public var screenLocked: Bool
    public var screensAsleep: Bool
    /// False while another user's session is on the console (fast user switching).
    public var sessionActive: Bool
    /// Seconds since the last keyboard, mouse or trackpad event.
    public var idleSeconds: Double

    public init(screenLocked: Bool = false, screensAsleep: Bool = false, sessionActive: Bool = true, idleSeconds: Double = 0) {
        self.screenLocked = screenLocked
        self.screensAsleep = screensAsleep
        self.sessionActive = sessionActive
        self.idleSeconds = idleSeconds
    }
}

/// Away mode's decisions. Pure: the caller owns the signals and the clock.
public enum PresenceLogic {
    /// The minutes Settings offers for "Away after:".
    public static let awayAfterChoices = [5, 10, 15, 30, 60]
    public static let defaultAwayAfterMinutes = 10

    /// Home and Away are "set by you". Automatic reports the first signal that
    /// holds, in this order: screen locked, displays asleep, switched user, idle.
    public static func evaluate(
        mode: PresenceMode, signals: PresenceSignals, awayAfterMinutes: Int
    ) -> (state: PresenceState, reason: String) {
        switch mode {
        case .home:
            return (.home, "set by you")
        case .away:
            return (.away, "set by you")
        case .auto:
            if signals.screenLocked { return (.away, "screen locked") }
            if signals.screensAsleep { return (.away, "displays asleep") }
            if !signals.sessionActive { return (.away, "switched user") }
            if signals.idleSeconds >= Double(awayAfterMinutes) * 60 {
                return (.away, "idle \(awayAfterMinutes) min")
            }
            return (.home, "active")
        }
    }

    /// The notification shown on return; nil when nothing arrived.
    public static func returnSummary(count: Int) -> String? {
        switch count {
        case ..<1: return nil
        case 1: return "1 ask arrived while you were away"
        default: return "\(count) asks arrived while you were away"
        }
    }

    /// The status menu's line: "Away · screen locked · since 10:22" or "Home · active".
    /// `since` is already formatted, in the user's locale.
    public static func statusLine(state: PresenceState, reason: String, since: String) -> String {
        switch state {
        case .home: return "Home · \(reason)"
        case .away: return "Away · \(reason) · since \(since)"
        }
    }
}

/// While away, new asks are counted instead of shown; on return the count
/// becomes one summary notification. Pure, like `NotifyPolicy`.
public struct AwayTally: Sendable, Equatable {
    public private(set) var state: PresenceState
    public private(set) var count = 0

    public init(state: PresenceState = .home) {
        self.state = state
    }

    /// True when these asks may notify and slide the panel in (home); while
    /// away they are counted and the answer is false.
    public mutating func arrived(_ count: Int) -> Bool {
        guard state == .away else { return true }
        self.count += max(0, count)
        return false
    }

    /// The summary to post when this change returns home with asks counted;
    /// the count starts again from zero.
    public mutating func changed(to next: PresenceState) -> String? {
        defer { state = next }
        guard state == .away, next == .home else { return nil }
        let summary = PresenceLogic.returnSummary(count: count)
        count = 0
        return summary
    }
}

/// `~/.local/state/relay/away`, present only while Relay says the owner is away,
/// so other tools can tell (ssh's `Match exec "test -e …"`, for example).
/// Two lines: `since=<ISO 8601 UTC>` and `reason=<reason>`.
public struct AwayFlag: Sendable {
    public let directory: URL

    public var file: URL { directory.appending(path: "away") }

    public init(directory: URL) {
        self.directory = directory
    }

    /// `~/.local/state/relay`.
    public static var standard: AwayFlag {
        AwayFlag(directory: FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".local/state/relay", directoryHint: .isDirectory))
    }

    /// The file's contents.
    public static func contents(reason: String, since: Date) -> String {
        let line = reason.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
        return "since=\(since.formatted(.iso8601))\nreason=\(line)\n"
    }

    /// A regular file at the path; a symlink doesn't count.
    public var isSet: Bool {
        var info = stat()
        return lstat(file.path, &info) == 0 && info.st_mode & S_IFMT == S_IFREG
    }

    /// Writes the flag atomically through `PrivateFile.write` in a 0700 directory.
    /// A symlink at the file's path is refused, never followed or replaced.
    @discardableResult
    public func set(reason: String, since: Date) -> Result<Void, any Error> {
        Result {
            try PrivateFile.ensureDirectory(directory)
            var info = stat()
            if lstat(file.path, &info) == 0, info.st_mode & S_IFMT == S_IFLNK {
                throw PrivateFile.TrustError.untrustedFile("\(file.path) is a symlink; refusing to use it")
            }
            try PrivateFile.write(Data(Self.contents(reason: reason, since: since).utf8), to: file)
        }
    }

    /// Removes the file (`unlink` never follows a symlink). Already gone is success.
    @discardableResult
    public func clear() -> Result<Void, any Error> {
        guard unlink(file.path) != 0, errno != ENOENT else { return .success(()) }
        return .failure(POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO))
    }
}
