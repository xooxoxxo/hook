import RelayCore
import Foundation

/// The crash about to be offered, written (with fsync) before the bar or the notification
/// goes up, to `Application Support/Relay/crash-offer.json`. If the run then dies before
/// `CrashOfferGuard.survival` has passed, the next launch knows the offer itself was fatal and
/// backs off instead of offering again, which would loop: find, offer, die, find again.
public struct CrashOfferRecord: Codable, Equatable, Sendable {
    /// `CrashSummary.handledKey`.
    public var key: String
    public var signature: String
    /// The run that made the offer.
    public var pid: Int32
    public var at: Date
    /// The run was still up `survival` after the offer.
    public var survived: Bool
    /// The back-off Notice was shown for this offer.
    public var noticeShown: Bool

    public init(key: String, signature: String, pid: Int32, at: Date, survived: Bool = false, noticeShown: Bool = false) {
        self.key = key
        self.signature = signature
        self.pid = pid
        self.at = at
        self.survived = survived
        self.noticeShown = noticeShown
    }
}

public enum CrashOfferGuard {
    /// An offer that lived this long didn't kill the run.
    public static let survival: TimeInterval = 20

    public enum Verdict: Equatable, Sendable {
        case clear
        /// The last run died with this offer up for less than `survival`.
        case diedOffering(CrashOfferRecord)
    }

    public static func url(dataDirectory: URL) -> URL {
        dataDirectory.appending(path: "crash-offer.json", directoryHint: .notDirectory)
    }

    public static func verdict(previous: RunMarker?, record: CrashOfferRecord?) -> Verdict {
        guard let previous, !previous.clean, let record, record.pid == previous.pid, !record.survived else { return .clear }
        return .diedOffering(record)
    }

    /// The back-off Notice: at most once for each offer that killed a run.
    public static let backOffNotice = "Hook closed while offering a crash report at its last start, so it won't offer "
        + "that one again. Save Diagnostics… in Settings › Privacy collects what happened."

    public static func read(_ url: URL) -> CrashOfferRecord? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder.marker.decode(CrashOfferRecord.self, from: data)
    }

    public static func write(_ record: CrashOfferRecord, to url: URL) throws {
        try PrivateFile.write(LaunchHistory.encoder.encode(record), to: url)
    }
}

/// One start of Hook, in `Application Support/Relay/launches.json` (the last few).
public struct LaunchRecord: Codable, Equatable, Sendable {
    public var pid: Int32
    public var started: Date
    /// Still up `LaunchHistory.window` after it started.
    public var survived: Bool
    /// Quit through AppKit (any cause), so it didn't die.
    public var clean: Bool

    public init(pid: Int32, started: Date, survived: Bool = false, clean: Bool = false) {
        self.pid = pid
        self.started = started
        self.survived = survived
        self.clean = clean
    }

    /// Ended without quitting and before `window`: a launch crash, a kill, or a hang killed.
    public var diedEarly: Bool { !survived && !clean }
}

/// The launch-crash guard: when each of the last `strikes` runs died within `window` of its
/// start, this start skips the crash offer and the other optional launch work (the update
/// check, the agents sync) and logs it. A run that lives past `window` clears it.
public enum LaunchHistory {
    public static let window: TimeInterval = 15
    public static let strikes = 3
    static let kept = 8

    public static func url(dataDirectory: URL) -> URL {
        dataDirectory.appending(path: "launches.json", directoryHint: .notDirectory)
    }

    /// True when the last `strikes` runs before this one all died early.
    public static func safeMode(_ previous: [LaunchRecord]) -> Bool {
        let last = previous.suffix(strikes)
        return last.count == strikes && last.allSatisfy(\.diedEarly)
    }

    public static let safeModeNotice = "Hook closed soon after starting 3 times in a row, so this start skipped the "
        + "crash report check, the update check and the agents sync. Save Diagnostics… in Settings › Privacy "
        + "collects what happened."

    /// Adds this run and returns the runs before it. A file that can't be read starts over.
    @discardableResult
    public static func begin(_ run: LaunchRecord, at url: URL) throws -> [LaunchRecord] {
        let previous = read(url)
        try write(Array((previous + [run]).suffix(kept)), to: url)
        return previous
    }

    /// This run lived past `window`.
    public static func markSurvived(pid: Int32, at url: URL) throws {
        try update(pid: pid, at: url) { $0.survived = true }
    }

    /// This run quit through AppKit.
    public static func markClean(pid: Int32, at url: URL) throws {
        try update(pid: pid, at: url) { $0.clean = true }
    }

    private static func update(pid: Int32, at url: URL, _ change: (inout LaunchRecord) -> Void) throws {
        var runs = read(url)
        guard let index = runs.lastIndex(where: { $0.pid == pid }) else { return }
        change(&runs[index])
        try write(runs, to: url)
    }

    public static func read(_ url: URL) -> [LaunchRecord] {
        guard let data = try? Data(contentsOf: url),
              let runs = try? JSONDecoder.marker.decode([LaunchRecord].self, from: data) else { return [] }
        return Array(runs.suffix(kept))
    }

    private static func write(_ runs: [LaunchRecord], to url: URL) throws {
        try PrivateFile.write(encoder.encode(runs), to: url)
    }

    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

/// What a start does about the last run, from its marker, the launch history, the last offer
/// and a quit request left for it.
public struct StartPlan: Equatable, Sendable {
    /// How the last run ended (logged either way).
    public var lastRun: LastRun
    /// The last 3 runs died early: no crash offer, no optional launch work.
    public var safeMode: Bool
    /// The last run died while offering this: it is handled now and never offered again.
    public var backOff: CrashOfferRecord?

    /// Offer the last run's crash (or close) only when neither guard tripped.
    public var offers: Bool { !safeMode && backOff == nil }

    public static func make(previous: RunMarker?, history: [LaunchRecord], offer: CrashOfferRecord?,
                            request: QuitRequest?, currentPID: Int32, isRunningHook: (Int32) -> Bool) -> StartPlan {
        let lastRun = LastRun.classify(previous, currentPID: currentPID, isRunningHook: isRunningHook, request: request)
        var backOff: CrashOfferRecord?
        if case .diedOffering(let record) = CrashOfferGuard.verdict(previous: previous, record: offer) { backOff = record }
        return StartPlan(lastRun: lastRun, safeMode: LaunchHistory.safeMode(history), backOff: backOff)
    }
}
