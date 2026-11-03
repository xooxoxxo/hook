import Foundation

/// A strict semver 2.0.0 version. Build metadata is dropped when parsing, so two versions
/// that differ only in it are equal, as precedence says.
public struct SemVer: Comparable, Hashable, Sendable, CustomStringConvertible {
    public var major: Int
    public var minor: Int
    public var patch: Int
    public var prerelease: [String]

    public init(major: Int, minor: Int, patch: Int, prerelease: [String] = []) {
        self.major = major; self.minor = minor; self.patch = patch; self.prerelease = prerelease
    }

    /// `MAJOR.MINOR.PATCH`, an optional `-pre.release` and an optional `+build`. No leading
    /// zeros, no `v`, no partial versions, ASCII digits only: "2026.10.27.1" → nil.
    public init?(strict text: String) {
        var rest = Substring(text)
        if let plus = rest.firstIndex(of: "+") {
            let build = rest[rest.index(after: plus)...]
            guard Self.identifiers(build, numericRule: false) != nil else { return nil }
            rest = rest[..<plus]
        }
        var pre: [String] = []
        if let dash = rest.firstIndex(of: "-") {
            guard let ids = Self.identifiers(rest[rest.index(after: dash)...], numericRule: true) else { return nil }
            pre = ids
            rest = rest[..<dash]
        }
        let core = rest.split(separator: ".", omittingEmptySubsequences: false)
        guard core.count == 3 else { return nil }
        var numbers: [Int] = []
        for part in core {
            guard Self.isNumber(part), let n = Int(part) else { return nil }
            numbers.append(n)
        }
        self.init(major: numbers[0], minor: numbers[1], patch: numbers[2], prerelease: pre)
    }

    public var description: String {
        "\(major).\(minor).\(patch)" + (prerelease.isEmpty ? "" : "-" + prerelease.joined(separator: "."))
    }

    /// -1, 0 or 1 by semver 2.0.0 §11.
    public static func compare(_ a: SemVer, _ b: SemVer) -> Int {
        for (x, y) in [(a.major, b.major), (a.minor, b.minor), (a.patch, b.patch)] where x != y {
            return x < y ? -1 : 1
        }
        return comparePrerelease(a.prerelease, b.prerelease)
    }

    public static func < (a: SemVer, b: SemVer) -> Bool { compare(a, b) < 0 }

    /// No pre-release ranks above any; numeric identifiers compare numerically and below
    /// alphanumeric ones; a shorter list of equal identifiers ranks lower.
    static func comparePrerelease(_ a: [String], _ b: [String]) -> Int {
        if a.isEmpty || b.isEmpty { return (b.isEmpty ? 0 : 1) - (a.isEmpty ? 0 : 1) }
        for (x, y) in zip(a, b) where x != y {
            let xn = isDigits(Substring(x)), yn = isDigits(Substring(y))
            if xn && yn {
                // Equal length after the no-leading-zero rule means a plain text compare is numeric.
                if x.count != y.count { return x.count < y.count ? -1 : 1 }
                return x.unicodeScalars.lexicographicallyPrecedes(y.unicodeScalars) ? -1 : 1
            }
            if xn != yn { return xn ? -1 : 1 }
            return x.unicodeScalars.lexicographicallyPrecedes(y.unicodeScalars) ? -1 : 1
        }
        return a.count == b.count ? 0 : (a.count < b.count ? -1 : 1)
    }

    static func isDigits(_ s: Substring) -> Bool {
        !s.isEmpty && s.unicodeScalars.allSatisfy { ("0"..."9").contains($0) }
    }

    /// `0|[1-9][0-9]*`.
    static func isNumber(_ s: Substring) -> Bool {
        isDigits(s) && (s.count == 1 || s.first != "0")
    }

    /// Dot-separated `[0-9A-Za-z-]+` identifiers; with `numericRule`, an all-digit one has
    /// no leading zero. nil when any is empty or malformed.
    static func identifiers(_ s: Substring, numericRule: Bool) -> [String]? {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        for part in parts {
            guard !part.isEmpty, part.unicodeScalars.allSatisfy(isIdentifierScalar) else { return nil }
            if numericRule && isDigits(part) && !isNumber(part) { return nil }
        }
        return parts.map(String.init)
    }

    static func isIdentifierScalar(_ c: Unicode.Scalar) -> Bool {
        ("0"..."9").contains(c) || ("a"..."z").contains(c) || ("A"..."Z").contains(c) || c == "-"
    }
}

public enum SemverRangeError: Error, Equatable, Sendable, LocalizedError {
    /// Names the bad part ("^1.1", "empty").
    case invalid(String)

    public var errorDescription: String? {
        switch self {
        case .invalid(let part): return "invalid range: " + part
        }
    }
}

/// Where a version falls against a range.
public enum RangeFit: String, Equatable, Sendable {
    case satisfies
    /// Below every set's lower bound.
    case below
    /// Same major as some set, past its upper bound: no Notice.
    case above
    /// A major above every set's lower-bound major.
    case newerMajor
}

/// An npm-style range: sets joined by `||`, each a space-separated list of comparators that
/// must all hold. A comparator is `^V`, `~V`, `>=V`, `>V`, `<=V`, `<V`, `=V` or a bare `V`
/// (exact), V strict. Partial versions, x-ranges, `*` and hyphen ranges are refused.
/// The same rules as clients/relay_semver.py, held to Fixtures/semver-vectors.json.
public struct SemverRange: Equatable, Sendable, CustomStringConvertible {
    enum Op: String, Sendable, CaseIterable {
        case gte = ">=", gt = ">", lte = "<=", lt = "<", eq = "="
    }

    struct Comparator: Equatable, Sendable {
        var op: Op
        var bound: SemVer

        func holds(_ v: SemVer) -> Bool {
            let c = SemVer.compare(v, bound)
            switch op {
            case .gte: return c >= 0
            case .gt: return c > 0
            case .lte: return c <= 0
            case .lt: return c < 0
            case .eq: return c == 0
            }
        }
    }

    let text: String
    let sets: [[Comparator]]

    public var description: String { text }

    public init(_ text: String) throws {
        var sets: [[Comparator]] = []
        for part in text.components(separatedBy: "||") {
            let tokens = part.split(separator: " ", omittingEmptySubsequences: true)
            guard !tokens.isEmpty else {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                throw SemverRangeError.invalid(trimmed.isEmpty ? "empty" : trimmed)
            }
            var comparators: [Comparator] = []
            for token in tokens {
                comparators += try Self.comparators(token)
            }
            sets.append(comparators)
        }
        self.text = text
        self.sets = sets
    }

    /// The operators in the order they are tried, so ">=" wins over ">".
    private static let prefixes = ["^", "~", ">=", ">", "<=", "<", "="]

    private static func comparators(_ token: Substring) throws -> [Comparator] {
        let prefix = prefixes.first { token.hasPrefix($0) } ?? ""
        guard let v = SemVer(strict: String(token.dropFirst(prefix.count))) else {
            throw SemverRangeError.invalid(String(token))
        }
        switch prefix {
        case "^": return [Comparator(op: .gte, bound: v), Comparator(op: .lt, bound: caretUpper(v))]
        case "~": return [Comparator(op: .gte, bound: v),
                          Comparator(op: .lt, bound: SemVer(major: v.major, minor: v.minor + 1, patch: 0))]
        case "": return [Comparator(op: .eq, bound: v)]
        default: return [Comparator(op: Op(rawValue: prefix)!, bound: v)]
        }
    }

    private static func caretUpper(_ v: SemVer) -> SemVer {
        if v.major > 0 { return SemVer(major: v.major + 1, minor: 0, patch: 0) }
        if v.minor > 0 { return SemVer(major: 0, minor: v.minor + 1, patch: 0) }
        return SemVer(major: 0, minor: 0, patch: v.patch + 1)
    }

    /// A pre-release only matches a set that names its `MAJOR.MINOR.PATCH` with a
    /// pre-release (the npm rule), so `^1.1.0` never picks up 1.2.0-rc.1.
    public func contains(_ v: SemVer) -> Bool {
        sets.contains { set in
            guard set.allSatisfy({ $0.holds(v) }) else { return false }
            if v.prerelease.isEmpty { return true }
            return set.contains {
                !$0.bound.prerelease.isEmpty
                    && ($0.bound.major, $0.bound.minor, $0.bound.patch) == (v.major, v.minor, v.patch)
            }
        }
    }

    public func fit(_ v: SemVer) -> RangeFit {
        if contains(v) { return .satisfies }
        let lows = sets.map(Self.lower)
        if lows.allSatisfy({ low in
            let c = SemVer.compare(v, low.bound)
            return c < 0 || (c == 0 && !low.inclusive)
        }) {
            return .below
        }
        if lows.allSatisfy({ v.major > $0.bound.major }) { return .newerMajor }
        return .above
    }

    /// A set's lower bound; 0.0.0 inclusive when it names none.
    private static func lower(_ set: [Comparator]) -> (bound: SemVer, inclusive: Bool) {
        var best = SemVer(major: 0, minor: 0, patch: 0), inclusive = true
        for comparator in set where [.gte, .gt, .eq].contains(comparator.op) {
            let c = SemVer.compare(comparator.bound, best)
            if c > 0 || (c == 0 && comparator.op == .gt) {
                best = comparator.bound
                inclusive = comparator.op != .gt
            }
        }
        return (best, inclusive)
    }
}

/// A Pond's version: semver from 1.0.0 on, or an old dated Pond read by its `protocol`.
public enum PondVersion: Equatable, Sendable {
    case semver(SemVer)
    case legacy(protocol: Int)

    /// A strict semver `version` is used as it is; anything else is an old Pond read by
    /// `protocol` (missing or below 1: 1, as a Pond without `/version`).
    public static func from(version: String?, protocol level: Int?) -> PondVersion {
        if let version, let v = SemVer(strict: version) { return .semver(v) }
        return .legacy(protocol: level.flatMap { $0 >= 1 ? $0 : nil } ?? 1)
    }

    /// What the gates compare: protocol 4 and above was what is now 1.0.0; N below 4 is 0.N.0.
    public var effective: SemVer {
        switch self {
        case .semver(let v): return v
        case .legacy(let level):
            return level >= 4 ? SemVer(major: 1, minor: 0, patch: 0) : SemVer(major: 0, minor: level, patch: 0)
        }
    }

    /// The Pond has the feature: its effective version is at least the feature's first one.
    public func supports(_ feature: MailboxFeature) -> Bool {
        effective >= feature.minimumPond
    }

    /// "1.1.0", or "protocol 4" for an old Pond.
    public var display: String {
        switch self {
        case .semver(let v): return v.description
        case .legacy(let level): return "protocol \(level)"
        }
    }
}

/// The Pond range this Hook needs, and what This Mac mode's built-in queue implements.
public enum PondCompat {
    public static let required = "^1.1.0"
    public static let localVersion = "1.0.0"
    /// Parsed once; SemverTests parses `required`, so a typo fails a test, not the app.
    public static let range: SemverRange = try! SemverRange(required)
}
