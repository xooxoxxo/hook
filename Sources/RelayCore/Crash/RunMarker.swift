import Foundation

/// What Hook writes at launch to `run-state.json` and marks clean on any quit that goes
/// through AppKit, with the quit's cause. An unclean marker at the next launch means the last
/// run ended badly; a clean one whose cause wasn't expected means something closed it.
/// `cause` and `ended` are new in 0.14 and optional, so a marker from an older version still
/// reads (as clean or unclean, with no cause).
public struct RunMarker: Codable, Equatable, Sendable {
    public var pid: Int32
    public var version: String
    public var started: Date
    public var clean: Bool
    public var cause: QuitCause?
    public var ended: Date?

    public init(pid: Int32, version: String, started: Date, clean: Bool = false, cause: QuitCause? = nil,
                ended: Date? = nil) {
        self.pid = pid
        self.version = version
        self.started = started
        self.clean = clean
        self.cause = cause
        self.ended = ended
    }
}

public enum RunMarkerStore {
    /// `Application Support/Relay/run-state.json`.
    public static func url(dataDirectory: URL) -> URL {
        dataDirectory.appending(path: "run-state.json", directoryHint: .notDirectory)
    }

    /// Writes this run's marker and returns the one before it (nil when there was none or
    /// it can't be read).
    @discardableResult
    public static func begin(_ marker: RunMarker, at url: URL) throws -> RunMarker? {
        let previous = read(url)
        try write(marker, to: url)
        return previous
    }

    /// Marks this run's marker clean, with why it quit and when. A missing marker is left
    /// missing, and with `pid` a marker another run wrote (a copy started after this one) is
    /// left alone.
    public static func markClean(at url: URL, pid: Int32? = nil, cause: QuitCause? = nil, ended: Date? = nil) throws {
        guard var marker = read(url) else { return }
        guard !marker.clean, pid.map({ $0 == marker.pid }) ?? true else { return }
        marker.clean = true
        marker.cause = cause
        marker.ended = ended
        try write(marker, to: url)
    }

    /// The previous run, when it ended without a clean quit. A marker whose pid is still a
    /// running Hook (another copy that is up) didn't crash; our own pid never counts as running.
    public static func uncleanEnd(_ previous: RunMarker?, currentPID: Int32,
                                  isRunningHook: (Int32) -> Bool) -> RunMarker? {
        guard let previous, !previous.clean else { return nil }
        if previous.pid != currentPID, isRunningHook(previous.pid) { return nil }
        return previous
    }

    public static func read(_ url: URL) -> RunMarker? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder.marker.decode(RunMarker.self, from: data)
    }

    private static func write(_ marker: RunMarker, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        try PrivateFile.write(encoder.encode(marker), to: url)
    }
}

extension JSONDecoder {
    static var marker: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
