import Foundation

/// Reads credentials at request time. Synchronous reads run on `KeychainQueue` in the client.
public protocol TokenSource: Sendable {
    func readToken() throws -> String
    /// Secure by default; the legacy Mac file source also supports HTTP Ponds.
    var requiresHTTPS: Bool { get }
}

extension TokenSource {
    public var requiresHTTPS: Bool { true }
}

public struct FileTokenSource: TokenSource {
    public let path: String
    public var requiresHTTPS: Bool { false }

    public init(path: String) { self.path = path }

    public func readToken() throws -> String {
        let expanded = (path as NSString).expandingTildeInPath
        let raw = (try? String(contentsOfFile: expanded, encoding: .utf8)) ?? ""
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw ConfigError.unreadableToken(expanded) }
        return token
    }
}

public enum TokenSourceError: Error, Equatable, Sendable, LocalizedError {
    case unreadableToken

    public var errorDescription: String? { "Hook couldn't read the Pond token from the Keychain. Unlock this device and try again." }
}

public struct KeychainTokenSource: TokenSource {
    private let store: any SecretStore
    private let name: SecretName

    public init(store: any SecretStore, name: SecretName) {
        self.store = store
        self.name = name
    }

    public func readToken() throws -> String {
        do {
            guard let data = try store.read(name), let raw = String(data: data, encoding: .utf8) else {
                throw TokenSourceError.unreadableToken
            }
            let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty else { throw TokenSourceError.unreadableToken }
            return token
        } catch {
            // Neither stored bytes nor an injected store's error text may appear in UI/logs.
            throw TokenSourceError.unreadableToken
        }
    }
}
