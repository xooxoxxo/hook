import Foundation

/// Private, versioned pairing material. Never describe or log an instance.
public struct PhonePairing: Codable, Sendable, Equatable {
    public let v: Int
    public let url: URL
    public let token: String
    public let context: String
    public static let maximumBytes = 16 * 1024

    public enum Failure: Error, LocalizedError {
        case tooLarge, malformed, version, destination, credentials
        public var errorDescription: String? {
            switch self {
            case .tooLarge: "The setup code is too large. Generate a new code on your Mac."
            case .malformed: "This isn't a Hook setup code."
            case .version: "This setup version isn't supported. Update Hook and try again."
            case .destination: "The Pond address must be HTTPS, without login details, a query or a fragment."
            case .credentials: "The setup code has no valid token."
            }
        }
    }

    public static func decode(_ data: Data) throws -> PhonePairing {
        guard data.count <= maximumBytes else { throw Failure.tooLarge }
        guard let ordered = try? OrderedJSON.parse(data), !OrderedJSON.hasDuplicateKeys(ordered),
              let value = try? JSONDecoder().decode(Self.self, from: data) else { throw Failure.malformed }
        guard value.v == 1 else { throw Failure.version }
        guard let parts = URLComponents(url: value.url, resolvingAgainstBaseURL: false),
              parts.scheme?.lowercased() == "https", let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.port.map({ (1...65535).contains($0) }) ?? true else { throw Failure.destination }
        guard !value.token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !value.token.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { throw Failure.credentials }
        var canonical = URLComponents(url: value.url.standardized, resolvingAgainstBaseURL: false)!
        canonical.scheme = "https"; canonical.host = host.lowercased()
        if canonical.port == 443 { canonical.port = nil }
        while canonical.percentEncodedPath.hasSuffix("/") { canonical.percentEncodedPath.removeLast() }
        guard let url = canonical.url else { throw Failure.destination }
        return Self(v: value.v, url: url, token: value.token, context: value.context)
    }

    /// Builds the same validated v1 format the phone accepts. No second validation path.
    public static func make(url: URL, token: String, context: String) throws -> PhonePairing {
        try decode(JSONEncoder().encode(Self(v: 1, url: url, token: token, context: context)))
    }

    /// The stable endpoint/context namespace. Credentials never enter it.
    public var sourceKey: String {
        SourceKey.mailbox(MailboxSettings(url: url, tokenFile: "", context: context))
    }
}
