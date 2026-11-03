import Foundation

/// The crash report as an ask for the owner's own Pond: project "Hook", the crash's title,
/// and one informational step whose `code` is the report exactly as the sheet showed it
/// (log lines dropped oldest first to fit 4,000 characters).
public enum BugAsk {
    public static let project = "Hook"
    /// A step's `code` limit in the instructable format.
    public static let codeLimit = 4000
    static let titleLimit = 120
    public static let step = "Read the crash report and fix the cause in Hook"
    public static let why = "Hook quit unexpectedly. The report holds only Hook's own crash fields and its redacted "
        + "activity log; the crash file itself isn't attached."

    /// The instructable's JSON bytes, keys sorted.
    public static func instructable(_ s: CrashSummary, body: String) -> Data {
        let object: [String: Any] = [
            "v": 1,
            "title": title(s),
            "why": why,
            "urgency": "whenever",
            "steps": [["do": step, "code": code(body), "lang": "text"]],
        ]
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]))
            ?? Data("{}".utf8)
    }

    /// The report cut to the `code` limit, counted the way the validator counts (code points).
    public static func code(_ body: String) -> String {
        CrashReportText.fit(body) { $0.unicodeScalars.count <= codeLimit }.text
    }

    /// The summary's title, kept to 120 characters with its signature at the end.
    public static func title(_ s: CrashSummary) -> String {
        guard s.title.count > titleLimit else { return s.title }
        let tail = " (\(s.signature))"
        return String(s.title.prefix(titleLimit - tail.count - 1)) + "…" + tail
    }
}
