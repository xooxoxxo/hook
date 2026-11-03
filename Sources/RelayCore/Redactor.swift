import Foundation

/// Takes personal and secret values out of a line before it is logged or sent:
/// the home folder becomes `~`, the user name `<user>`, URLs, hosts and IP addresses
/// `<host>`, ids `<id>`, and token-like runs `<redacted>`. Running it twice changes nothing,
/// so a report can redact again what the log already redacted.
public enum Redactor {
    public static func redact(_ s: String, home: String, user: String) -> String {
        var text = s
        let home = home.hasSuffix("/") ? String(home.dropLast()) : home
        if home.count > 1 { text = text.replacingOccurrences(of: home, with: "~") }
        for rule in rules { text = rule.apply(text) }
        if !user.isEmpty, user.count > 1 {
            text = replace(text, pattern: #"(?<![A-Za-z0-9_<])"# + NSRegularExpression.escapedPattern(for: user) + #"(?![A-Za-z0-9_>])"#,
                           with: "<user>")
        }
        return text
    }

    private struct Rule: Sendable {
        let regex: NSRegularExpression
        let template: String
        func apply(_ s: String) -> String {
            regex.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template)
        }
    }

    /// The top-level names a dotted word must end in to count as a host. File names
    /// (`config.json`, `Hook.app`, `install.sh`) and symbols (`SettingsWindow.open`) don't.
    private static let topLevel = "com|net|org|io|dev|local|lan|internal|home|arpa|ai|co|cloud|xyz|info|edu|gov|uk|de|tr|eu|us"

    private static let hex = "[0-9A-Fa-f]{1,4}"

    /// In order: each rule sees what the ones before it left.
    private static let rules: [Rule] = [
        // Another account's home folder, after `home` itself became ~.
        (#"/Users/[^/\s<>"']+"#, "/Users/<user>"),
        (#"(?i)\bbearer\s+[^\s"',;]+"#, "Bearer <redacted>"),
        (#"(?i)\b(token|password|passwd|secret|api[_-]?key|key|auth)=[^\s"'&,;]+"#, "$1=<redacted>"),
        (#"\b(?:gh[pousr]_|github_pat_)[A-Za-z0-9_]{10,}"#, "<redacted>"),
        (#"\bsk-[A-Za-z0-9_-]{10,}"#, "<redacted>"),
        (#"\bxox[abprs]-[A-Za-z0-9-]{10,}"#, "<redacted>"),
        (#"\b[A-Za-z][A-Za-z0-9+.-]*://[^\s"'<>]+"#, "<host>"),
        (#"\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b"#, "<redacted>"),
        (#"\b[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\b"#, "<id>"),
        (#"(?<![0-9A-Za-z:])(?:\#(hex):){7}\#(hex)(?![0-9A-Za-z:])"#, "<host>"),
        (#"(?<![0-9A-Za-z:])(?:\#(hex)(?::\#(hex))*)?::(?:\#(hex)(?::\#(hex))*)?(?![0-9A-Za-z:])"#, "<host>"),
        (#"\b(?:\d{1,3}\.){3}\d{1,3}(?::\d{1,5})?\b"#, "<host>"),
        (#"(?i)\b[a-z0-9](?:[a-z0-9-]*[a-z0-9])?(?:\.[a-z0-9-]+)*\.(?:\#(topLevel))(?::\d{1,5})?\b"#, "<host>"),
        (#"\b[A-Za-z][A-Za-z0-9-]*(?:\.[A-Za-z0-9-]+)*:\d{2,5}\b"#, "<host>"),
        (#"\b[0-9A-Fa-f]{32,}\b"#, "<redacted>"),
        // A long run that mixes letters and digits, as keys and tokens do.
        (#"(?<![$A-Za-z0-9_-])(?=[A-Za-z0-9_-]*[0-9])(?=[A-Za-z0-9_-]*[A-Za-z])[A-Za-z0-9_-]{40,}(?![A-Za-z0-9_-])"#, "<redacted>"),
    ].map { pattern, template in
        // The patterns are constants; a bad one is a programming error caught by the tests.
        Rule(regex: try! NSRegularExpression(pattern: pattern), template: template)
    }

    private static func replace(_ s: String, pattern: String, with template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return s }
        return regex.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s),
                                              withTemplate: NSRegularExpression.escapedTemplate(for: template))
    }
}
