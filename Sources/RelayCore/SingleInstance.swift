import Foundation

/// Which running app counts as another Hook. The launch check runs before
/// the loopback server and the queue lock.
public enum SingleInstance {
    /// A running app as the launch check sees it.
    public struct Copy: Equatable, Sendable {
        public var bundleID: String?
        public var pid: Int32
        /// When its process started; nil when unknown.
        public var started: Date?

        public init(bundleID: String?, pid: Int32, started: Date?) {
            self.bundleID = bundleID
            self.pid = pid
            self.started = started
        }

        /// Earlier start first; a copy without a start time counts as started last; the pid breaks ties.
        func startedBefore(_ other: Copy) -> Bool {
            let mine = started ?? .distantFuture, theirs = other.started ?? .distantFuture
            return mine != theirs ? mine < theirs : pid < other.pid
        }
    }

    /// The pid of the copy to hand off to: the earliest-started other app with Hook's bundle id,
    /// if it started before `me`. A copy that started later hands off to this one instead, so two
    /// copies started together never both quit. nil when there is none.
    public static func older(than me: Copy, running: [Copy]) -> Int32? {
        running
            .filter { $0.bundleID != nil && $0.bundleID == me.bundleID && $0.pid != me.pid && $0.startedBefore(me) }
            .min { $0.startedBefore($1) }?
            .pid
    }
}
