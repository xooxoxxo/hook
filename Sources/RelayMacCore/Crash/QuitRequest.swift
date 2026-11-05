import Foundation
import RelayCore

/// What install.sh (and get.sh, and the updater's job through them) writes to
/// `Application Support/Relay/quit-request.json` just before it signals a running Hook:
/// `{"by":"installer","pid":123,"at":1793600000}`. Hook reads it when the signal comes, and
/// the next launch reads it when the installer had to force-quit.
public struct QuitRequest: Equatable, Sendable {
    public var cause: QuitCause
    public var at: Date

    public init(cause: QuitCause, at: Date) {
        self.cause = cause
        self.at = at
    }

    /// A request answers a signal only when it is this recent.
    public static let freshFor: TimeInterval = 120

    public static func url(dataDirectory: URL) -> URL {
        dataDirectory.appending(path: "quit-request.json", directoryHint: .notDirectory)
    }

    /// The request, when the file is there and says installer or updater; nil otherwise.
    public static func parse(_ data: Data) -> QuitRequest? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let by = object["by"] as? String, let at = (object["at"] as? NSNumber)?.doubleValue else { return nil }
        let kind: QuitCause.Kind
        switch by {
        case "installer": kind = .installer
        case "updater": kind = .updater
        default: return nil
        }
        let pid = (object["pid"] as? NSNumber).map { Int32(truncatingIfNeeded: $0.int64Value) }
        return QuitRequest(cause: QuitCause(kind, pid: pid), at: Date(timeIntervalSince1970: at))
    }

    /// Reads and removes the file. Every read removes it, so an old request never answers a
    /// later signal.
    public static func take(dataDirectory: URL) -> QuitRequest? {
        let url = url(dataDirectory: dataDirectory)
        guard let data = try? Data(contentsOf: url) else { return nil }
        try? FileManager.default.removeItem(at: url)
        return parse(data)
    }

    /// Asked within `freshFor` of `now` (a clock a little behind counts too).
    public func isFresh(now: Date) -> Bool {
        let age = now.timeIntervalSince(at)
        return age >= -5 && age <= Self.freshFor
    }
}

/// How the last run ended, read at launch from its marker (and a quit request left for it).
public enum LastRun: Equatable, Sendable {
    /// No marker, a quit that was expected, or a clean marker from before 0.14 (no cause).
    case fine
    /// Ended without marking itself clean after the installer or updater asked it to quit:
    /// install.sh force-quit it. Logged, not offered.
    case forceQuit(RunMarker, QuitCause)
    /// Ended without marking itself clean: a crash, a hang, a force quit or a kill.
    case crashed(RunMarker)
    /// Quit cleanly, but for a cause nobody expected (a signal, another app's request, code).
    case closed(RunMarker, QuitCause)

    /// A marker whose pid is still a running Hook (another copy that is up) ended fine.
    public static func classify(_ previous: RunMarker?, currentPID: Int32, isRunningHook: (Int32) -> Bool,
                                request: QuitRequest?) -> LastRun {
        guard let previous else { return .fine }
        if previous.clean {
            guard let cause = previous.cause, !cause.expected else { return .fine }
            return .closed(previous, cause)
        }
        guard let ended = RunMarkerStore.uncleanEnd(previous, currentPID: currentPID, isRunningHook: isRunningHook)
        else { return .fine }
        if let request, request.at >= ended.started { return .forceQuit(ended, request.cause) }
        return .crashed(ended)
    }
}
