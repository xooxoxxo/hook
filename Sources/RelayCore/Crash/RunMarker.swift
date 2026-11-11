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
