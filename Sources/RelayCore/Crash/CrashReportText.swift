import Foundation

/// Exactly what Send delivers, and what the sheet previews: the summary's allowed fields
/// (Hook and macOS versions, CPU type, the exception, Hook's own frames, the source kind and
/// Pond version) plus the last 40 log lines. Everything is redacted again here, on top of
/// the log's own redaction. The .ips itself is never attached.
public enum CrashReportText {
    public static let logLines = 40

    public static let signatureLine: @Sendable (String) -> String = { "Crash signature: hook-crash-\($0)" }

    /// `source` is "Pond" or "This Mac"; `pond` its version when known.
    public static func body(_ s: CrashSummary, source: String, pond: String?, log: [String],
                            home: String = defaultHome, user: String = NSUserName()) -> String {
        func row(_ label: String, _ value: String) -> String {
            label.padding(toLength: 11, withPad: " ", startingAt: 0) + value
        }
        let indent = String(repeating: " ", count: 11)
        var lines = [s.title, signatureLine(s.signature), ""]
        lines.append(row("Hook", "\(s.hookVersion) (\(s.cpu)) · macOS \(s.macOS)"))
        lines.append(row("Source", pond.map { "\(source) \($0)" } ?? source))
        if let report = s.report {
            lines.append(row("Exception", report.signal.map { "\(report.exception) (\($0))" } ?? report.exception))
            if let reason = report.termination { lines.append(row("Reason", reason)) }
            for (i, frame) in report.appFrames.enumerated() {
                let text: String
                if let symbol = frame.symbol {
                    text = CrashSummary.bareSymbol(symbol) + (frame.offset.map { " +\($0)" } ?? "")
                } else {
                    text = "Hook +0x" + String(frame.imageOffset, radix: 16)
                }
                lines.append(i == 0 ? row("Frames", text) : indent + text)
            }
        } else {
            lines.append(row("Exception", "none: no crash report (a hang, a force quit or a kill)"))
        }
        let tail = log.suffix(logLines)
        lines.append("")
        lines.append("Last \(tail.count) log lines")
        lines.append(contentsOf: tail.map(RollingLog.oneLine))
        return lines.map { Redactor.redact($0, home: home, user: user) }.joined(separator: "\n")
    }

    /// Drops log lines, oldest first, until `fits` says yes; the "Last N log lines" header
    /// follows the count. The title, the signature line and the fields above the log always
    /// stay; if even no log lines don't fit, the text is cut at the end. `trimmed` is true
    /// when anything was dropped.
    public static func fit(_ body: String, _ fits: (String) -> Bool) -> (text: String, trimmed: Bool) {
        guard !fits(body) else { return (body, false) }
        var lines = body.components(separatedBy: "\n")
        guard let header = lines.lastIndex(where: { $0.hasPrefix("Last ") && $0.hasSuffix(" log lines") }) else {
            return (cut(body, fits), true)
        }
        var log = Array(lines[(header + 1)...])
        lines.removeSubrange((header + 1)...)
        while !log.isEmpty {
            log.removeFirst()
            lines[header] = "Last \(log.count) log lines"
            let text = (lines + log).joined(separator: "\n")
            if fits(text) { return (text, true) }
        }
        return (cut(lines.joined(separator: "\n"), fits), true)
    }

    /// The longest prefix that fits, on a line boundary when one is left.
    private static func cut(_ text: String, _ fits: (String) -> Bool) -> String {
        var lines = text.components(separatedBy: "\n")
        while lines.count > 1 {
            lines.removeLast()
            let shorter = lines.joined(separator: "\n")
            if fits(shorter) { return shorter }
        }
        var single = lines.first ?? ""
        while !single.isEmpty, !fits(single) { single.removeLast() }
        return single
    }

    public static var defaultHome: String { ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory() }
}
