import Foundation
import os

/// Local timestamps: UTC, whole seconds and the literal offset "+00:00",
/// never "Z", so Python 3.9's `fromisoformat` reads them. The formatters aren't
/// Sendable, so each is built once and used only under its lock.
public enum Timestamp {
    public static func string(_ date: Date) -> String {
        writer.withLock { $0.formatter.string(from: date) }
    }

    /// Accepts any "+HH:MM" offset and "Z". Nil for anything else.
    /// The queue parses the same stamps on every list and every render, so answers are
    /// kept (up to `parseCacheLimit`, then the cache starts over).
    public static func date(_ text: String) -> Date? {
        parser.withLock { state in
            if let known = state.cache[text] { return known }
            let parsed = state.formatter.date(from: text)
            if state.cache.count >= parseCacheLimit { state.cache.removeAll(keepingCapacity: true) }
            state.cache[text] = .some(parsed)
            return parsed
        }
    }

    static let parseCacheLimit = 2048

    private struct Parser: @unchecked Sendable {
        let formatter: ISO8601DateFormatter
        var cache: [String: Date?] = [:]
    }

    private struct Writer: @unchecked Sendable {
        let formatter: DateFormatter
    }

    private static let parser: OSAllocatedUnfairLock<Parser> = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return OSAllocatedUnfairLock(initialState: Parser(formatter: formatter))
    }()

    private static let writer = OSAllocatedUnfairLock(
        initialState: Writer(formatter: utcFormatter("yyyy-MM-dd'T'HH:mm:ss'+00:00'")))

    /// "20261011-093000", for `queue.json.corrupt-<stamp>`.
    public static func fileStamp(_ date: Date) -> String {
        utcFormatter("yyyyMMdd-HHmmss").string(from: date)
    }

    private static func utcFormatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = format
        return formatter
    }
}
