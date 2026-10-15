import Foundation

/// The local-mode API: a request in, a response out. Framing has
/// already happened (in the listener). Checks run in order: Host, browsers, route, auth,
/// JSON; then the route calls the queue. No CORS headers are ever sent.
public actor LocalAPI {
    static let defaultDays = 14
    static let maxDays = 36500
    static let defaultLimit = 100
    static let maxLimit = 1000

    private let queue: LocalQueue
    private let port: Int
    private let token: @Sendable () -> String?
    private var seen: [String: Date] = [:]

    public init(queue: LocalQueue, port: Int, token: @escaping @Sendable () -> String?) {
        self.queue = queue
        self.port = port
        self.token = token
    }

    enum Route: Equatable {
        case postAsk, listAsks, getAsk(String), resolve(String), events

        init?(method: String, path: String) {
            let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            switch (method, parts.count) {
            case ("GET", 2) where parts == ["", "asks"]:
                self = .listAsks
            case ("POST", 2) where parts == ["", "asks"]:
                self = .postAsk
            case ("GET", 2) where parts == ["", "events"]:
                self = .events
            case ("GET", 3) where parts[0].isEmpty && parts[1] == "asks" && !parts[2].isEmpty:
                self = .getAsk(parts[2])
            case ("POST", 4) where parts[0].isEmpty && parts[1] == "asks" && !parts[2].isEmpty && parts[3] == "resolve":
                self = .resolve(parts[2])
            default:
                return nil
            }
        }
    }

    public func handle(_ request: HTTPRequest) async -> HTTPResponse {
        let headers = Dictionary(
            request.headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { $0 + "," + $1 })

        // 1. Host: a rebound DNS name still carries its own Host.
        guard Self.hostAllowed(headers["host"], port: port) else { return .error(403, "forbidden") }
        // 2. No browsers.
        if headers["origin"] != nil { return .error(403, "forbidden") }
        if let site = headers["sec-fetch-site"],
           site.trimmingCharacters(in: .whitespaces).lowercased() != "none" {
            return .error(403, "forbidden")
        }
        // 3. Route.
        guard let route = Route(method: request.method, path: request.path) else {
            return .error(404, "not found")
        }
        // 4. Auth.
        guard authorized(headers["authorization"]) else { return .error(401, "unauthorized") }
        noteClient(headers["x-relay-client"])

        // 5. JSON (POST routes only), then the route.
        switch route {
        case .listAsks:
            return await listAsks(request.query)
        case .getAsk(let rawID):
            return await getAsk(rawID)
        case .events:
            return await events(request.query)
        case .postAsk:
            guard let body = Self.object(request.body) else { return Self.badBody(request.body) }
            return await postAsk(body)
        case .resolve(let rawID):
            guard let body = Self.object(request.body) else { return Self.badBody(request.body) }
            return await resolve(rawID, body)
        }
    }

    public func lastSeen() -> [String: Date] {
        seen
    }

    // MARK: - Routes

    private func postAsk(_ body: [String: JSONValue]) async -> HTTPResponse {
        do {
            let result = try await queue.post(project: body["project"], instructable: body["instructable"])
            guard let item = Self.value(result.item) else { return .error(500, "store failed") }
            var object: [String: JSONValue] = [
                "item": item,
                "openUrl": .string("http://127.0.0.1:\(port)/i/\(result.item.id)"),
            ]
            if result.deduped { object["deduped"] = .bool(true) }
            return .json(result.deduped ? 200 : 201, .object(object))
        } catch {
            return Self.failure(error)
        }
    }

    private func listAsks(_ query: [String: String]) async -> HTTPResponse {
        let status = query["status"] ?? "open"
        guard ["open", "done", "dismissed", "all"].contains(status),
              let days = Self.integer(query["days"], default: Self.defaultDays, in: 0...Self.maxDays) else {
            return .error(400, "invalid query")
        }
        let items = await queue.list(status: status, days: days)
        guard let values = Self.values(items) else { return .error(500, "store failed") }
        return .json(200, .object(["items": .array(values)]))
    }

    private func getAsk(_ rawID: String) async -> HTTPResponse {
        guard let id = QueueLogic.normalizedID(rawID), let found = await queue.get(id) else {
            return .error(404, "not found")
        }
        guard let item = Self.value(found.item), let events = Self.values(found.events) else {
            return .error(500, "store failed")
        }
        return .json(200, .object(["item": item, "events": .array(events)]))
    }

    private func resolve(_ rawID: String, _ body: [String: JSONValue]) async -> HTTPResponse {
        guard let verdict = body["verdict"]?.stringValue, verdict == "done" || verdict == "declined" else {
            return .error(400, "invalid verdict")
        }
        switch body["actor"] {
        case nil, .null?, .string("")?, .string("session")?:
            break
        case .string("owner")?:
            return .error(403, "owner actions are app-only")
        default:
            return .error(400, "invalid actor")
        }
        guard let id = QueueLogic.normalizedID(rawID) else { return .error(404, "not found") }
        do {
            let item = try await queue.resolve(id, verdict: verdict, actor: "session", note: body["note"])
            guard let value = Self.value(item) else { return .error(500, "store failed") }
            return .json(200, .object(["item": value]))
        } catch {
            return Self.failure(error)
        }
    }

    private func events(_ query: [String: String]) async -> HTTPResponse {
        guard let after = Self.integer(query["after"], default: 0, in: 0...Int.max),
              let limit = Self.integer(query["limit"], default: Self.defaultLimit, in: 1...Self.maxLimit) else {
            return .error(400, "invalid query")
        }
        let page = await queue.events(after: after, limit: limit)
        let epoch = await queue.epoch
        guard let events = Self.values(page.events) else { return .error(500, "store failed") }
        return .json(200, .object([
            "events": .array(events),
            "next": .int(page.next),
            "epoch": .string(epoch),
        ]))
    }

    // MARK: - Checks

    static func hostAllowed(_ host: String?, port: Int) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return host == "127.0.0.1:\(port)" || host == "localhost:\(port)"
    }

    private func authorized(_ header: String?) -> Bool {
        let prefix = "Bearer "
        guard let header, header.hasPrefix(prefix), let expected = token(), !expected.isEmpty else { return false }
        return LocalToken.matches(String(header.dropFirst(prefix.count)), expected)
    }

    /// "cli/0.3.1" or "mcp/0.3.1" → the Connect tab's "last seen".
    private func noteClient(_ header: String?) {
        guard let kind = header?.split(separator: "/", maxSplits: 1).first?.lowercased(),
              kind == "cli" || kind == "mcp" else { return }
        seen[kind] = Date()
    }

    // MARK: - Helpers

    /// The body as a JSON object; empty counts as {}. nil when it isn't one.
    static func object(_ body: Data) -> [String: JSONValue]? {
        if body.isEmpty { return [:] }
        guard body.count <= RequestFraming.maxBody,
              case .object(let fields)? = try? JSONValue.parse(body) else { return nil }
        return fields
    }

    static func badBody(_ body: Data) -> HTTPResponse {
        body.count > RequestFraming.maxBody ? .error(413, "body too large") : .error(400, "invalid json")
    }

    /// nil when `raw` is present but not an integer in `range`.
    static func integer(_ raw: String?, default fallback: Int, in range: ClosedRange<Int>) -> Int? {
        guard let raw else { return fallback }
        guard let value = Int(raw), range.contains(value) else { return nil }
        return value
    }

    static func failure(_ error: any Error) -> HTTPResponse {
        guard let error = error as? LocalQueueError else { return .error(500, "store failed") }
        let wire = error.wire
        return .error(wire.status, wire.error, details: wire.details)
    }

    /// A stored record as JSON with every key, nulls included. nil when it can't
    /// be encoded; callers answer 500, never a 2xx with a null.
    static func value<T: Encodable>(_ record: T) -> JSONValue? {
        guard let data = try? JSONEncoder().encode(record) else { return nil }
        return try? JSONValue.parse(data)
    }

    /// nil when any record fails to encode.
    static func values<T: Encodable>(_ records: [T]) -> [JSONValue]? {
        var out: [JSONValue] = []
        for record in records {
            guard let value = value(record) else { return nil }
            out.append(value)
        }
        return out
    }
}
