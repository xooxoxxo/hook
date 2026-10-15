import Foundation

/// What the loopback server does with one request.
public enum LinkDecision: Equatable, Sendable {
    case health
    /// Open the item with this canonical lowercase id.
    case open(id: String)
    case notFound
    /// Answer 403 and never bring Relay forward.
    case forbidden
}

/// Which requests to 127.0.0.1:<port> may bring Relay forward. A link that an app
/// such as a chat app hands to the browser is a top-level navigation the user
/// started; a web page's image, fetch, script or cross-site navigation is not.
public enum LinkPolicy {
    /// `headers` are matched case-insensitively.
    public static func decide(method: String, path: String, headers: [String: String], port: Int) -> LinkDecision {
        let headers = Dictionary(
            headers.map { ($0.key.lowercased(), $0.value.trimmingCharacters(in: .whitespaces)) },
            uniquingKeysWith: { first, second in first + "," + second })

        // A rebound DNS name pointing at 127.0.0.1 still carries its own Host.
        let host = headers["host"]?.lowercased()
        guard host == "127.0.0.1:\(port)" || host == "localhost:\(port)" else { return .forbidden }
        guard method == "GET" else { return .notFound }

        let route = path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
            .first.map(String.init) ?? ""
        if route == "/health" { return .health }
        // Relay's own links never carry a query; one on /i/ is not a Relay link.
        guard route == path, route.hasPrefix("/i/"), let id = QueueLogic.normalizedID(String(route.dropFirst(3))) else {
            return .notFound
        }
        // Browsers send Sec-Fetch-*; curl and other tools do not.
        if headers.keys.contains(where: { $0.hasPrefix("sec-fetch-") }) {
            guard headers["sec-fetch-dest"] == "document", headers["sec-fetch-site"] == "none" else {
                return .forbidden
            }
        }
        return .open(id: id)
    }
}
