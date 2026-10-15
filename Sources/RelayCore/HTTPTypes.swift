import Foundation

/// One request after framing: what `LocalAPI` sees.
public struct HTTPRequest: Sendable {
    public var method: String
    public var path: String
    public var query: [String: String]
    /// Names lowercased; a repeated header's values joined with ",".
    public var headers: [String: String]
    public var body: Data

    public init(method: String, path: String, query: [String: String], headers: [String: String], body: Data) {
        self.method = method
        self.path = path
        self.query = query
        self.headers = headers
        self.body = body
    }

    /// RFC 9110 `tchar`: what a header name may contain.
    private static let tokenCharacters = CharacterSet(
        charactersIn: "!#$%&'*+-.^_`|~0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")

    /// Parses "METHOD target HTTP/1.x\r\n" + headers, up to the first blank line.
    /// nil for anything malformed; the server answers that with 400.
    public static func parseHead(
        _ head: Data
    ) -> (method: String, path: String, query: [String: String], headers: [String: String])? {
        guard var text = String(data: head, encoding: .isoLatin1) else { return nil }
        if let end = text.range(of: "\r\n\r\n") { text = String(text[..<end.lowerBound]) }
        var lines = text.components(separatedBy: "\r\n")
        while lines.count > 1, lines.last == "" { lines.removeLast() }

        let requestLine = lines[0].split(separator: " ", omittingEmptySubsequences: false)
        guard requestLine.count == 3 else { return nil }
        let method = String(requestLine[0])
        let target = requestLine[1]
        let version = requestLine[2]
        guard !method.isEmpty,
              method.unicodeScalars.allSatisfy({ ("A"..."Z").contains($0) }),
              version == "HTTP/1.1" || version == "HTTP/1.0",
              target.hasPrefix("/") else { return nil }

        let split = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        guard let query = parseQuery(split.count > 1 ? split[1] : "") else { return nil }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { return nil }
            let name = line[..<colon]
            guard !name.isEmpty, name.unicodeScalars.allSatisfy({ tokenCharacters.contains($0) }) else { return nil }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
            let key = name.lowercased()
            headers[key] = headers[key].map { $0 + "," + value } ?? value
        }
        return (method, String(split[0]), query, headers)
    }

    /// "a=1&b=x+y" → ["a": "1", "b": "x y"]; the first value of a name wins.
    static func parseQuery(_ raw: Substring) -> [String: String]? {
        var query: [String: String] = [:]
        for pair in raw.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let name = decode(parts[0]), let value = decode(parts.count > 1 ? parts[1] : "") else { return nil }
            if query[name] == nil { query[name] = value }
        }
        return query
    }

    private static func decode(_ text: Substring) -> String? {
        text.replacingOccurrences(of: "+", with: " ").removingPercentEncoding
    }
}

public struct HTTPResponse: Sendable, Equatable {
    public var status: Int
    public var headers: [String: String]
    public var body: Data

    public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    public static func json(_ status: Int, _ object: JSONValue) -> HTTPResponse {
        HTTPResponse(
            status: status,
            headers: ["Content-Type": "application/json", "Cache-Control": "no-store"],
            body: object.data())
    }

    /// `{"error": message}`, plus `details` (field paths only, never values).
    public static func error(_ status: Int, _ message: String, details: [String]? = nil) -> HTTPResponse {
        var object: [String: JSONValue] = ["error": .string(message)]
        if let details { object["details"] = .array(details.map(JSONValue.string)) }
        return json(status, .object(object))
    }

    /// The whole response for the wire. Always `Connection: close`.
    public func serialized() -> Data {
        var head = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
        for (name, value) in headers.sorted(by: { $0.key < $1.key }) {
            let lower = name.lowercased()
            guard lower != "connection", lower != "content-length" else { continue }
            head += "\(Self.stripLineBreaks(name)): \(Self.stripLineBreaks(value))\r\n"
        }
        head += "Connection: close\r\nContent-Length: \(body.count)\r\n\r\n"
        return Data(head.utf8) + body
    }

    /// Defence in depth: a CR or LF in a header would split the response.
    private static func stripLineBreaks(_ text: String) -> String {
        text.filter { $0 != "\r" && $0 != "\n" && $0 != "\r\n" }
    }

    static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 201: return "Created"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 413: return "Content Too Large"
        case 429: return "Too Many Requests"
        case 500: return "Internal Server Error"
        case 503: return "Service Unavailable"
        default: return "Status"
        }
    }
}

public enum FramingDecision: Sendable, Equatable {
    case read(bodyLength: Int)
    case reject(HTTPResponse)
}

/// What to do after the head and before any other check.
public enum RequestFraming {
    public static let maxBody = 65536

    public static func decide(method: String, headers: [String: String]) -> FramingDecision {
        let headers = Dictionary(
            headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { $0 + "," + $1 })
        if headers["transfer-encoding"] != nil { return .reject(.error(400, "bad request")) }
        var length = 0
        if let raw = headers["content-length"] {
            let digits = raw.trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
            guard (1...7).contains(digits.utf8.count),
                  digits.utf8.allSatisfy({ (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }),
                  let value = Int(digits) else {
                return .reject(.error(400, "bad request"))
            }
            guard value <= maxBody else { return .reject(.error(413, "body too large")) }
            length = value
        }
        return .read(bodyLength: method == "POST" ? length : 0)
    }
}

/// `GET /health`. No auth; the proof lets a client check it is
/// talking to this Relay before it sends the token.
public enum Health {
    public static func response(source: String, port: Int, nonce: String?, token: String?) -> HTTPResponse {
        var object: [String: JSONValue] = [
            "ok": .bool(true),
            "app": .string("relay"),
            "source": .string(source),
        ]
        if source == "local", let nonce, LocalToken.isValidNonce(nonce), let token, !token.isEmpty {
            object["proof"] = .string(LocalToken.proof(token: token, port: port, nonce: nonce))
        }
        return .json(200, .object(object))
    }
}
