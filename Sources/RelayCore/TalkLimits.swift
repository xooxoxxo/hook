import Foundation

/// How much the owner may say to the session at once: messages and problem reports. Pond 1.4.0
/// takes 8000 characters of each and keeps a report's line breaks; an older Pond, or one whose
/// version check hasn't answered yet, keeps 1000 and 300, and a report on one line. Counts are
/// Unicode scalars, as Python's `len`. A text over the cap is never cut: the field keeps it and
/// says how much to trim.
public struct TalkLimits: Equatable, Sendable {
    public var message: Int
    public var report: Int
    public var multilineReports: Bool

    public init(message: Int, report: Int, multilineReports: Bool) {
        self.message = message
        self.report = report
        self.multilineReports = multilineReports
    }

    /// Before Pond 1.4.0 (and This Mac, which has no session channel).
    public static let old = TalkLimits(message: 1000, report: 300, multilineReports: false)
    /// Pond 1.4.0.
    public static let long = TalkLimits(message: 8000, report: 8000, multilineReports: true)

    /// nil (no answer yet) is an older Pond.
    public static func make(pond: PondVersion?) -> TalkLimits {
        pond?.supports(.longText) == true ? .long : .old
    }

    /// The counter shows past 80 % of the limit.
    public static func showsCounter(_ count: Int, limit: Int) -> Bool {
        count * 10 > limit * 8
    }

    /// "7 412 / 8 000", digits grouped by U+202F.
    public static func counter(_ count: Int, limit: Int) -> String {
        grouped(count) + " / " + grouped(limit)
    }

    /// "Trim 1 204 characters to send." over the limit; nil at or under it.
    public static func over(_ count: Int, limit: Int) -> String? {
        guard count > limit else { return nil }
        let extra = count - limit
        return "Trim \(grouped(extra)) character\(extra == 1 ? "" : "s") to send."
    }

    /// Thousands grouped by a narrow no-break space (U+202F), whatever the locale.
    static func grouped(_ number: Int) -> String {
        let digits = String(number)
        var out = ""
        for (index, digit) in digits.enumerated() {
            if index > 0, (digits.count - index) % 3 == 0 { out.append("\u{202F}") }
            out.append(digit)
        }
        return out
    }
}
