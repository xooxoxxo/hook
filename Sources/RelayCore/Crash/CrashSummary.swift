import CryptoKit
import Foundation

/// One crash of an earlier run: what the bar, the sheet and a report show.
public struct CrashSummary: Equatable, Sendable {
    /// 12 hex characters: SHA-256 over the exception and the top three app frames (symbols,
    /// offsets removed). Unsymbolicated frames hash their image offsets plus the Hook version,
    /// and so does a run with no report.
    public var signature: String
    /// The version that crashed (from the run marker).
    public var hookVersion: String
    public var macOS: String
    public var cpu: String
    /// nil: a hang, a force quit or a kill; the report carries only the log.
    public var report: IPSReport?
    public var when: Date
    /// "Hook crash: EXC_BAD_ACCESS in SettingsWindow.open (a3f9c2e17b04)".
    public var title: String
    /// The .ips it was read from, for Show in Finder; never sent.
    public var reportFile: URL?
    /// The run quit cleanly, but for a cause nobody expected (a signal, another app, code).
    public var closed: QuitCause?
    /// When the run that ended started; with no report it tells one run from the next.
    public var run: Date?

    public init(report: IPSReport?, hookVersion: String, macOS: String, cpu: String, when: Date, reportFile: URL? = nil,
                closed: QuitCause? = nil, run: Date? = nil) {
        self.report = report
        self.reportFile = reportFile
        self.hookVersion = hookVersion
        self.macOS = macOS
        self.cpu = cpu
        self.when = when
        self.closed = report == nil ? closed : nil
        self.run = run
        let signature = Self.signature(report: report, closed: self.closed, hookVersion: hookVersion)
        self.signature = signature
        self.title = Self.title(report: report, closed: self.closed, signature: signature)
    }

    /// What Not Now and a send remember, so it isn't raised again. A crash report's signature
    /// names that crash; a run without one (no report, or closed) is only that run, so the
    /// next one like it is raised too. Before 0.14 every report-less end of a version shared
    /// one signature, so after one Not Now the bar never came back for that version.
    public var handledKey: String {
        guard report == nil else { return signature }
        return "\(signature)@\(Int((run ?? when).timeIntervalSince1970))"
    }

    static func signature(report: IPSReport?, closed: QuitCause? = nil, hookVersion: String) -> String {
        var parts: [String]
        if let report {
            let top = report.appFrames.prefix(3)
            parts = [report.exception] + top.map { frame in
                frame.symbol.map(bareSymbol) ?? "Hook+0x" + String(frame.imageOffset, radix: 16)
            }
            if top.contains(where: { $0.symbol == nil }) || top.isEmpty { parts.append(hookVersion) }
        } else if let closed {
            parts = ["closed", closed.kind.rawValue, closed.detail ?? "", closed.process ?? "", hookVersion]
        } else {
            parts = ["no-report", hookVersion]
        }
        let digest = SHA256.hash(data: Data(parts.joined(separator: "\n").utf8))
        return digest.map { String(format: "%02x", $0) }.joined().prefix(12).description
    }

    /// A symbol without a trailing `+ 52`.
    static func bareSymbol(_ s: String) -> String {
        s.replacingOccurrences(of: #"\s*\+\s*(0x[0-9A-Fa-f]+|\d+)$"#, with: "", options: .regularExpression)
    }

    /// `SettingsWindow.open(tab:)` → `SettingsWindow.open`.
    static func shortSymbol(_ s: String) -> String {
        let bare = bareSymbol(s)
        guard let paren = bare.firstIndex(of: "("), paren != bare.startIndex else { return bare }
        return String(bare[..<paren])
    }

    static func title(report: IPSReport?, closed: QuitCause? = nil, signature: String) -> String {
        if report == nil, let closed { return "Hook was closed: \(closed.text) (\(signature))" }
        guard let report else { return "Hook quit unexpectedly (\(signature))" }
        let place: String
        if let top = report.appFrames.first {
            place = top.symbol.map(shortSymbol) ?? "Hook +0x" + String(top.imageOffset, radix: 16)
        } else {
            place = "Hook"
        }
        return "Hook crash: \(report.exception) in \(place) (\(signature))"
    }
}

/// The launch check: reads the newest Hook crash report after the last run's start.
public enum CrashFinder {
    /// A garbled or missing report still counts as a crash, with no report.
    public static func find(previous: RunMarker, reports: URL, macOS: String, cpu: String) -> CrashSummary {
        var report: IPSReport?
        var when = previous.started
        let file = IPSReport.newest(in: reports, after: previous.started)
        if let url = file {
            report = IPSReport.read(url)
            if let date = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date {
                when = date
            }
        }
        return CrashSummary(report: report, hookVersion: previous.version, macOS: macOS, cpu: cpu, when: when,
                            reportFile: file, run: previous.started)
    }
}
