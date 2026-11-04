import Foundation

/// Why a run of Hook ended, as `hook.log`, the run marker and the next launch's crash bar
/// name it. A quit the owner asked for, a logout or shutdown, the updater and the installer
/// are expected; anything else (a signal from another process, another app's quit request,
/// a terminate from code) counts as unexpected and is offered at the next launch like a crash.
public struct QuitCause: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        /// The owner's Quit command: `detail` says where (menu, panel, menuBar).
        case user
        /// The updater's job, through install.sh.
        case updater
        /// install.sh or get.sh replacing the app.
        case installer
        /// A second copy that handed off to the running one and left.
        case duplicate
        case logout, restart, shutdown
        /// macOS said it is about to log out or power off, without saying which.
        case powerOff
        /// SIGTERM or SIGHUP: `detail` is TERM or HUP, `pid` and `process` the sender when known.
        case signal
        /// A quit Apple event from another app, without a logout or shutdown reason.
        case appleEvent
        /// `NSApp.terminate` or `exit` from Hook's own code: `detail` is the call site's tag.
        case code
    }

    public var kind: Kind
    public var detail: String?
    public var pid: Int32?
    public var process: String?

    public init(_ kind: Kind, detail: String? = nil, pid: Int32? = nil, process: String? = nil) {
        self.kind = kind
        self.detail = detail.map { Self.clean($0, limit: 32) }.flatMap { $0.isEmpty ? nil : $0 }
        self.pid = pid.flatMap { $0 > 0 ? $0 : nil }
        self.process = process.map { Self.clean($0, limit: 32) }.flatMap { $0.isEmpty ? nil : $0 }
    }

    public static func user(_ via: String) -> QuitCause { QuitCause(.user, detail: via) }
    public static func code(_ tag: String) -> QuitCause { QuitCause(.code, detail: tag) }
    public static func signal(_ name: String, pid: Int32?, process: String?) -> QuitCause {
        QuitCause(.signal, detail: name, pid: pid, process: process)
    }

    /// The owner's own quit, a logout or shutdown, the updater, the installer, or a second copy.
    public var expected: Bool {
        switch self.kind {
        case .user, .updater, .installer, .duplicate, .logout, .restart, .shutdown, .powerOff: return true
        case .signal, .appleEvent, .code: return false
        }
    }

    /// "SIGTERM from launchd (pid 1)": what the crash bar says after "Hook was closed: ".
    public var text: String {
        switch self.kind {
        case .user: return "you quit it"
        case .updater: return "the updater"
        case .installer: return "the installer"
        case .duplicate: return "a second copy left"
        case .logout: return "logout"
        case .restart: return "restart"
        case .shutdown: return "shutdown"
        case .powerOff: return "logout or shutdown"
        case .signal: return "SIG" + (detail ?? "TERM") + " from " + sender(fallback: "another process")
        case .appleEvent: return "a quit request from " + sender(fallback: "another app")
        case .code: return "Hook's own code (" + (detail ?? "terminate") + ")"
        }
    }

    private func sender(fallback: String) -> String {
        switch (process, pid) {
        case let (name?, pid?): return "\(name) (pid \(pid))"
        case let (name?, nil): return name
        case let (nil, pid?): return "pid \(pid)"
        case (nil, nil): return fallback
        }
    }

    /// The fields after `cause=` in a log line: `signal sig=TERM pid=1 from="launchd"`. The
    /// sender's name is quoted and redacted by the line; every other value is a plain word.
    public func logFields(quote: (String) -> String) -> String {
        var parts = [kind.rawValue]
        if let detail { parts.append((kind == .signal ? "sig=" : "via=") + detail.replacingOccurrences(of: " ", with: "-")) }
        if let pid { parts.append("pid=\(pid)") }
        if let process { parts.append("from=" + quote(process)) }
        return parts.joined(separator: " ")
    }

    /// The quit Apple event's reason (`kAEQuitReason`) as a cause: logout, restart or shutdown;
    /// without a reason, another app asked (its pid and name when the event says).
    public static func appleEvent(reason: UInt32?, senderPID: Int32?, sender: String?) -> QuitCause {
        switch reason {
        case fourCC("logo"), fourCC("rlgo"): return QuitCause(.logout)
        case fourCC("rrst"), fourCC("rest"): return QuitCause(.restart)
        case fourCC("rsdn"), fourCC("shut"): return QuitCause(.shutdown)
        default: return QuitCause(.appleEvent, pid: senderPID, process: sender)
        }
    }

    static func fourCC(_ s: String) -> UInt32 {
        s.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
    }

    /// Letters, digits, spaces and `._+-` only, cut to `limit`: a process name or a tag can't
    /// carry anything else into a log line or a report.
    static func clean(_ s: String, limit: Int) -> String {
        let kept = s.unicodeScalars.filter {
            $0.isASCII && (CharacterSet.alphanumerics.contains($0) || " ._+-".unicodeScalars.contains($0))
        }
        return String(String.UnicodeScalarView(kept.prefix(limit))).trimmingCharacters(in: .whitespaces)
    }
}

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
