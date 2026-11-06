import Foundation

/// A release version: `X.Y.Z`, with an optional leading "v". Anything else (a
/// pre-release suffix, a fourth part, a leading zero, letters) does not parse.
public struct ReleaseVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init?(_ raw: String) {
        var text = Substring(raw.trimmingCharacters(in: .whitespaces))
        if text.first == "v" { text = text.dropFirst() }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.count <= 9, part.allSatisfy({ $0.isASCII && $0.isNumber }),
                  part == "0" || part.first != "0", let n = Int(part) else { return nil }
            numbers.append(n)
        }
        major = numbers[0]
        minor = numbers[1]
        patch = numbers[2]
    }

    public var description: String { "\(major).\(minor).\(patch)" }

    public static func < (a: ReleaseVersion, b: ReleaseVersion) -> Bool {
        (a.major, a.minor, a.patch) < (b.major, b.minor, b.patch)
    }
}

/// The parts of GitHub's "latest release" reply that Hook reads.
public struct LatestRelease: Equatable, Sendable {
    /// The git tag, exactly as GitHub gives it ("v0.6.5").
    public let tag: String
    public let version: ReleaseVersion
    /// The release page, for the release notes.
    public let url: URL
    /// The mailbox level the release needs: its notes' `<!-- hook:mailbox-protocol=N -->`
    /// marker, or nil when the notes have none.
    public let mailboxLevel: Int?
    /// The Pond range the release needs: its notes' `<!-- hook:pond=<range> -->` marker, when it
    /// parses; nil otherwise (then `mailboxLevel` decides).
    public let pondRange: String?

    public init(tag: String, version: ReleaseVersion, url: URL, mailboxLevel: Int? = nil, pondRange: String? = nil) {
        self.tag = tag
        self.version = version
        self.url = url
        self.mailboxLevel = mailboxLevel
        self.pondRange = pondRange
    }

    /// nil for a reply that isn't a published, final release with a version tag and an https page.
    public static func parse(_ data: Data) -> LatestRelease? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = object["tag_name"] as? String,
              let version = ReleaseVersion(tag),
              let page = object["html_url"] as? String,
              let url = URL(string: page), url.scheme == "https", url.host != nil else { return nil }
        if object["draft"] as? Bool == true || object["prerelease"] as? Bool == true { return nil }
        let body = object["body"] as? String
        let level = body.flatMap(ReleaseMarker.mailboxLevel(in:))
        let range = body.flatMap(ReleaseMarker.pondRange(in:))?.description
        return LatestRelease(tag: tag, version: version, url: url, mailboxLevel: level, pondRange: range)
    }
}

/// What the menu knows about updates.
public enum UpdateState: Equatable, Sendable {
    case none
    case checking
    case available(version: String, tag: String, url: URL)
    case failed(reason: String)

    /// An update only when the release is strictly newer than the running version.
    /// A running version that doesn't parse (a development build) never offers one.
    public static func resolve(current: String, latest: LatestRelease?) -> UpdateState {
        guard let latest, let running = ReleaseVersion(current), latest.version > running else { return .none }
        return .available(version: latest.version.description, tag: latest.tag, url: latest.url)
    }

    /// The result of one check: the reply's body, or why there is none.
    public static func resolve(current: String, reply: Result<Data, UpdateCheckError>) -> UpdateState {
        switch reply {
        case .failure(let error):
            return .failed(reason: error.reason)
        case .success(let data):
            guard let latest = LatestRelease.parse(data) else {
                return .failed(reason: "GitHub's reply had no release version")
            }
            return resolve(current: current, latest: latest)
        }
    }

    public var availableVersion: String? {
        if case .available(let version, _, _) = self { return version }
        return nil
    }
}

public struct UpdateCheckError: LocalizedError, Equatable, Sendable {
    public let reason: String
    public init(_ reason: String) { self.reason = reason }
    public var errorDescription: String? { reason }
}

/// Automatic checks: about a minute after launch, then once a day.
public enum UpdateSchedule {
    public static let firstDelay: TimeInterval = 60
    public static let interval: TimeInterval = 24 * 60 * 60
}
