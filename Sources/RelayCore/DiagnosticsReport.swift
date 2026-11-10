import Foundation

/// Settings › Privacy › Save Diagnostics…: one redacted text file with what is
/// needed to tell why Hook closed on a Mac, ready to attach to an issue. The app collects
/// the parts (`Parts`); this builds and redacts the text.
public enum DiagnosticsReport {
    public struct Parts: Equatable, Sendable {
        public var hookVersion: String
        public var macOS: String
        public var cpu: String
        /// The copies of Hook LaunchServices and Spotlight know, by path.
        public var copies: [String]
        /// `launchctl print gui/<uid>/<label>`'s output (only some lines are kept), or why not.
        public var launchAgent: String
        public var runState: String?
        public var launches: String?
        public var hookLog: [String]
        public var updateLog: [String]
        /// "Hook-2026-11-02-221409.ips  2026-11-02 22:14  48 KB".
        public var crashFiles: [String]
        /// The last 2 h of system log lines about Hook, or why there are none.
        public var systemLog: [String]

        public init(hookVersion: String, macOS: String, cpu: String, copies: [String], launchAgent: String,
                    runState: String?, launches: String?, hookLog: [String], updateLog: [String],
                    crashFiles: [String], systemLog: [String]) {
            self.hookVersion = hookVersion
            self.macOS = macOS
            self.cpu = cpu
            self.copies = copies
            self.launchAgent = launchAgent
            self.runState = runState
            self.launches = launches
            self.hookLog = hookLog
            self.updateLog = updateLog
            self.crashFiles = crashFiles
            self.systemLog = systemLog
        }
    }

    public static let hookLogLines = 300
    public static let updateLogLines = 100
    public static let systemLogLines = 400
    /// `log show`'s window and predicate: the processes that start, watch and end apps, on
    /// lines that name Hook.
    public static let systemLogWindow = "2h"
    public static let systemLogPredicate = #"(process == "runningboardd" OR process == "launchd" OR "#
        + #"process == "loginwindow") AND eventMessage CONTAINS[c] "Hook""#
    /// The longest `log show` may take; it is stopped after this.
    public static let systemLogTimeout: TimeInterval = 30

    /// `hook-diagnostics-2026-11-04-1530.txt`.
    public static func fileName(now: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        return "hook-diagnostics-\(formatter.string(from: now)).txt"
    }

    /// Only launchctl's state, last exit code and runs lines.
    public static func launchAgentLines(_ output: String) -> [String] {
        output.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("state =") || $0.hasPrefix("last exit code =") || $0.hasPrefix("runs =") }
    }

    /// `hosts`: this Mac's names (its host name, and its computer name), each shown as `<host>`.
    public static func text(_ parts: Parts, now: Date, home: String, user: String, hosts: [String]) -> String {
        var lines = ["Hook diagnostics", "Saved     \(now.formatted(.iso8601))",
                     "Hook      \(parts.hookVersion) (\(parts.cpu)) · macOS \(parts.macOS)", ""]
        func section(_ title: String, _ body: [String], empty: String = "(none)") {
            lines.append("== \(title)")
            lines += body.isEmpty ? [empty] : body
            lines.append("")
        }
        section("Copies of Hook (LaunchServices and Spotlight)", parts.copies)
        let agent = launchAgentLines(parts.launchAgent)
        section("LaunchAgent (launchctl print: state, last exit code, runs)",
                agent.isEmpty ? [RollingLog.oneLine(parts.launchAgent).trimmingCharacters(in: .whitespaces)] : agent)
        section("run-state.json", parts.runState.map { [$0] } ?? [], empty: "(missing)")
        section("launches.json", parts.launches.map { [$0] } ?? [], empty: "(missing)")
        section("hook.log (last \(hookLogLines) lines)", Array(parts.hookLog.suffix(hookLogLines)), empty: "(empty)")
        section("update.log (last \(updateLogLines) lines)", Array(parts.updateLog.suffix(updateLogLines)), empty: "(empty)")
        section("Crash files for Hook (~/Library/Logs/DiagnosticReports)", parts.crashFiles)
        section("System log, last \(systemLogWindow) (runningboardd, launchd, loginwindow; lines naming Hook)",
                Array(parts.systemLog.suffix(systemLogLines)))
        return lines.map { redact($0, home: home, user: user, hosts: hosts) }.joined(separator: "\n")
    }

    /// The activity log's redactor, and this Mac's names as `<host>` too (with and without
    /// `.local`, any case), longest first.
    public static func redact(_ line: String, home: String, user: String, hosts: [String]) -> String {
        var text = line
        var names: [String] = []
        for host in hosts.map({ $0.trimmingCharacters(in: .whitespaces) }) where host.count > 1 {
            let bare = host.lowercased().hasSuffix(".local") ? String(host.dropLast(6)) : host
            names += [bare + ".local", bare].filter { $0.count > 1 }
        }
        for name in names.sorted(by: { $0.count > $1.count }) {
            text = text.replacingOccurrences(of: name, with: "<host>", options: .caseInsensitive)
        }
        return Redactor.redact(text, home: home, user: user)
    }
}
