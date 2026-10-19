/// Which running app counts as another Relay (§4.10). The launch check runs before
/// the loopback server and the queue lock.
public enum SingleInstance {
    /// The pid of a running app with Relay's bundle id that isn't this process; nil when none.
    public static func other(bundleID: String, myPID: Int32, running: [(bundleID: String?, pid: Int32)]) -> Int32? {
        running.first { $0.bundleID == bundleID && $0.pid != myPID }?.pid
    }
}
