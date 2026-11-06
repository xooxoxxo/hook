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
