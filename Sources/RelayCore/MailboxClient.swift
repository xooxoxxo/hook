import Foundation
import os

/// The last failure one client logged; cleared by a call that works.
final class FailureLog: Sendable {
    private let last = OSAllocatedUnfairLock<String?>(initialState: nil)

    /// True, and remembered, when `key` isn't the failure logged last.
    func isNew(_ key: String) -> Bool {
        last.withLock { last in
            guard last != key else { return false }
            last = key
            return true
        }
    }

    func clear() { last.withLock { $0 = nil } }
}

struct ListResponse: Decodable {
    let items: [WireItem]
}

struct ItemResponse: Decodable {
    let item: WireItem
}

struct ErrorBody: Decodable {
    let error: String
    let details: [String]?
    /// With "ask was corrected": the current revision and the one the owner accepted.
    let rev: Int?
    let hash: String?
    let acceptedRev: Int?
}

struct RequireResponse: Decodable {
    let required: Bool?
    let pending: Bool?
}

/// Refuses every HTTP redirect, so the bearer token only ever reaches the configured mailbox.
final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    static let shared = NoRedirectDelegate()
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? { nil }
}

/// The mailbox service as a `QueueSource`. The token is read from the token file
/// on every request, so it is never kept in memory longer than one call; so is the owner key.
public struct MailboxClient: QueueSource {
    /// What every request says this client reads: revision histories (Pond 1.1.0). Without
    /// it a corrected ask is served as a stub.
    public static let protocolHeader = "X-Hook-Protocol"
    public static let clientProtocol = "5"
    /// The owner key's header, sent on owner acts while this Mac's key is approved.
    public static let ownerKeyHeader = "X-Hook-Owner-Key"

    public let settings: MailboxSettings
    private let session: URLSession
    /// This client's last logged failure, so a Pond that stays down is logged once, not on every poll.
    private let failures = FailureLog()
    /// Read on each owner act, never stored: it returns this Mac's key only while the Pond
    /// has approved it (`OwnerKeyVault.approvedKey`).
    private let ownerKey: (@Sendable () -> String?)?

    public init(settings: MailboxSettings, session: URLSession = .shared, ownerKey: (@Sendable () -> String?)? = nil) {
        self.settings = settings
        self.session = session
        self.ownerKey = ownerKey
    }

    public init(baseURL: URL, tokenFile: String, context: String, session: URLSession = .shared) {
        self.init(settings: MailboxSettings(url: baseURL, tokenFile: tokenFile, context: context), session: session)
    }

    public func list() async throws -> [WireItem] {
        let query = [
            URLQueryItem(name: "status", value: "open"),
            URLQueryItem(name: "days", value: "36500"),
        ]
        let response: ListResponse = try await send("GET", "asks", query: query)
        return response.items
    }

    public func get(_ id: String) async throws -> AskDetail {
        try await send("GET", "asks/\(id)")
    }

    public func post(project: String, instructable: Data) async throws -> PostResult {
        let body = Self.postBody(project: project, context: settings.context, instructable: instructable)
        return try await send("POST", "asks", body: body)
    }

    /// Done or Skip from Hook: always `actor: "owner"`.
    public func resolve(_ id: String, verdict: Verdict, note: String?) async throws -> WireItem {
        try await resolve(id, verdict: verdict, note: note, stamp: nil)
    }

    /// A crash report (Pond 1.2.0): always with the owner key. Either 403 the owner check
    /// gives ("owner key required", "unknown owner key") is `.ownerKeyRefused`.
    public func postBug(project: String, instructable: Data, signature: String) async throws -> BugPostResult {
        let body = Self.postBody(project: project, context: settings.context, instructable: instructable,
                                 extra: ["kind": "bug", "signature": signature])
        do {
            let response: BugPostResponse = try await send("POST", "asks", body: body, owner: true)
            return response.result
        } catch QueueError.rejected(403, "owner key required", _) {
            throw QueueError.ownerKeyRefused
        }
    }

    /// Done or Skip bound to the revision the owner saw (`rev`, `hash`). A Pond whose
    /// revision in force differs answers 409 → `.corrected`.
    public func resolve(_ id: String, verdict: Verdict, note: String?, stamp: RevisionStamp?) async throws -> WireItem {
        var body: [String: JSONValue] = ["verdict": .string(verdict.rawValue), "actor": .string("owner")]
        if let note { body["note"] = .string(note) }
        Self.add(stamp, to: &body)
        let response: ItemResponse = try await send("POST", "asks/\(id)/resolve", body: JSONValue.object(body).data(),
                                                    owner: true)
        return response.item
    }

    public func reply(_ id: String, text: String) async throws -> WireItem {
        let response: ItemResponse = try await send("POST", "asks/\(id)/reply", body: Self.encode(["text": text]),
                                                    owner: true)
        return response.item
    }

    /// A message to the posting session (Pond 1.2.0): the reply route with `kind: "message"`.
    /// The text goes as typed. A closed ask or the 50-message cap answers 409, a secret-like
    /// text 400 (`MessageText.refusal` words both).
    public func message(_ id: String, text: String) async throws -> WireItem {
        let response: ItemResponse = try await send("POST", "asks/\(id)/reply",
                                                    body: Self.encode(["text": text, "kind": "message"]), owner: true)
        return response.item
    }

    /// `POST /asks/{id}/answers` with `{"answers":[...]}`. 409 (the ask is closed) → `.askClosed`.
    public func answer(_ id: String, answers: [JSONValue]) async throws -> WireItem {
        try await answer(id, answers: answers, stamp: nil)
    }

    /// Answers bound to the revision the owner saw. A 409 "ask was corrected" is `.corrected`
    /// (mapped in `send`, so it never reads as "This ask is closed"); any other 409 → `.askClosed`.
    public func answer(_ id: String, answers: [JSONValue], stamp: RevisionStamp?) async throws -> WireItem {
        var body: [String: JSONValue] = ["answers": .array(answers)]
        Self.add(stamp, to: &body)
        do {
            let response: ItemResponse = try await send("POST", "asks/\(id)/answers", body: JSONValue.object(body).data(),
                                                        owner: true)
            return response.item
        } catch QueueError.rejected(let status, _, _) where status == 409 {
            throw QueueError.askClosed
        }
    }

    /// Takes back a Done or Skip: always `actor: "owner"`. The mailbox returns an open
    /// ask unchanged.
    public func reopen(_ id: String) async throws -> WireItem {
        let response: ItemResponse = try await send("POST", "asks/\(id)/reopen", body: Self.encode(["actor": "owner"]),
                                                    owner: true)
        return response.item
    }

    /// The owner accepted this revision (Pond 1.1.0; always needs the owner key).
    public func accept(_ id: String, stamp: RevisionStamp) async throws -> WireItem {
        var body: [String: JSONValue] = [:]
        Self.add(stamp, to: &body)
        let response: ItemResponse = try await send("POST", "asks/\(id)/accept", body: JSONValue.object(body).data(),
                                                    owner: true)
        return response.item
    }

    /// A problem report on one step (by its id), bound to the revision shown (Pond 1.1.0;
    /// always needs the owner key).
    public func problem(_ id: String, stepID: String, stamp: RevisionStamp, note: String) async throws -> WireItem {
        var body: [String: JSONValue] = ["step": .string(stepID), "note": .string(note)]
        Self.add(stamp, to: &body)
        let response: ItemResponse = try await send("POST", "asks/\(id)/problems", body: JSONValue.object(body).data(),
                                                    owner: true)
        return response.item
    }

    /// `GET /owner`, with this Mac's key when approved, so `self` names it.
    public func ownerStatus() async throws -> OwnerStatus {
        try await send("GET", "owner", owner: true)
    }

    /// `POST /owner/enroll`: only the key's hash is sent, never a key.
    public func enroll(keyHash: String, label: String) async throws -> Enrollment {
        try await send("POST", "owner/enroll", body: Self.encode(["keyHash": keyHash, "label": label]))
    }

    public func enrollment(_ id: String) async throws -> Enrollment {
        try await send("GET", "owner/enroll/\(id)")
    }

    /// `POST /owner/require`: on takes effect at once; off waits for the owner's tap on
    /// Telegram (202 → `.pending`).
    public func requireOwnerKey(_ on: Bool) async throws -> OwnerKeyRequirement {
        let response: RequireResponse = try await send(
            "POST", "owner/require", body: JSONValue.object(["required": .bool(on)]).data(), owner: true)
        if response.pending == true { return .pending }
        guard let required = response.required else { throw QueueError.unreachable("bad response from the Pond") }
        return required ? .on : .off
    }

    static func add(_ stamp: RevisionStamp?, to body: inout [String: JSONValue]) {
        guard let stamp else { return }
        body["rev"] = .int(stamp.rev)
        body["hash"] = .string(stamp.hash)
    }

    /// The mailbox's `days` filter counts from creation, so both lists reach back
    /// `closedLookbackDays`; the completion window is applied here.
    public func recentlyClosed(within interval: TimeInterval) async throws -> [WireItem] {
        var merged: [WireItem] = []
        for status in ["done", "dismissed"] {
            let query = [
                URLQueryItem(name: "status", value: status),
                URLQueryItem(name: "days", value: String(Self.closedLookbackDays)),
            ]
            let response: ListResponse = try await send("GET", "asks", query: query)
            merged += response.items
        }
        return Self.closedWithin(merged, interval: interval, now: Date())
    }

    static let closedLookbackDays = 14

    /// Items whose `completedAt` is within `interval` of `now`, newest first. One
    /// without a readable `completedAt` is skipped; an id seen twice is kept once.
    static func closedWithin(_ items: [WireItem], interval: TimeInterval, now: Date) -> [WireItem] {
        let cutoff = now.addingTimeInterval(-interval)
        var seen = Set<String>()
        return items
            .compactMap { item -> (completed: Date, item: WireItem)? in
                guard item.status != "open",
                      let completed = item.completedAt.flatMap(Timestamp.date),
                      completed >= cutoff, seen.insert(item.id).inserted else { return nil }
                return (completed, item)
            }
            .sorted { $0.completed > $1.completed }
            .map(\.item)
    }

    /// `GET /version`: the Pond's version. A Pond from before `/version` answers 404, which
    /// counts as protocol 1.
    public func version() async throws -> MailboxVersion {
        do {
            return try await send("GET", "version", expected: [404])
        } catch QueueError.notFound {
            return .legacy
        }
    }

    /// The mailbox has no push channel; the Store polls.
    public func changes() async -> AsyncStream<Void>? {
        nil
    }

    /// `{"context":…,"project":…,"instructable":<raw>}`: the instructable's bytes
    /// are spliced in as given, so the mailbox validates exactly what the caller sent.
    static func postBody(project: String, context: String, instructable: Data, extra: [String: String] = [:]) -> Data {
        var body = encode(extra.merging(["context": context, "project": project]) { _, fixed in fixed })
        body.removeLast()   // the closing brace
        body.append(Data(#","instructable":"#.utf8))
        body.append(instructable)
        body.append(Data("}".utf8))
        return body
    }

    static func encode(_ object: [String: String]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]))
            ?? Data("{}".utf8)
    }

    /// `perform`, with a failure written to Hook's log as `error type=Pond status=… route=…`:
    /// the route is `path` cut to its template, and the message is a fixed phrase, a Pond
    /// error phrase or a URLError code, never an id, a title, the host or the token. A status
    /// in `expected` is an answer the caller handles, not a failure.
    private func send<T: Decodable>(
        _ method: String,
        _ path: String,
        query: [URLQueryItem] = [],
        body: Data? = nil,
        owner: Bool = false,
        expected: Set<Int> = []
    ) async throws -> T {
        do {
            let value: T = try await perform(method, path, query: query, body: body, owner: owner)
            failures.clear()
            return value
        } catch let failure as Transport {
            if let text = failure.logText { log(status: nil, path: path, message: text) }
            throw failure.error
        } catch let error as QueueError {
            let (status, message) = Self.logged(error)
            if let status, expected.contains(status) { throw error }
            log(status: status, path: path, message: message)
            throw error
        }
    }

    private func log(status: Int?, path: String, message: String) {
        let route = RouteTemplate.template(path)
        guard failures.isNew("\(status.map(String.init) ?? "-") \(route) \(message)") else { return }
        HookLog.error("Pond", message, status: status, route: route)
    }

    /// The status and the log text for a failure. A Pond's own error is kept only when it is a
    /// short lowercase phrase like the spec's ("ask is closed"); anything else is `HTTP <status>`.
    static func logged(_ error: QueueError) -> (status: Int?, message: String) {
        switch error {
        case .unreachable(let reason): return (nil, reason)
        case .unauthorized: return (401, "unauthorized")
        case .notFound: return (404, "not found")
        case .corrected: return (409, "ask was corrected")
        case .ownerKeyRefused: return (403, "unknown owner key")
        case .askClosed: return (409, "ask is closed")
        case .storeFailed: return (nil, "store failed")
        case .rejected(let status, let text, _):
            let phrase = text.range(of: "^[a-z][a-z ]{0,59}$", options: .regularExpression) != nil
            return (status, phrase ? text : "HTTP \(status)")
        }
    }

    /// A failure before any HTTP answer: `error` is thrown, `logText` (if any) is logged.
    private struct Transport: Error {
        let error: QueueError
        let logText: String?
    }

    private func perform<T: Decodable>(
        _ method: String,
        _ path: String,
        query: [URLQueryItem],
        body: Data?,
        owner: Bool
    ) async throws -> T {
        var components = URLComponents(
            url: settings.url.appending(path: path), resolvingAgainstBaseURL: false)
        if !query.isEmpty { components?.queryItems = query }
        guard let url = components?.url else { throw QueueError.unreachable("the Pond URL is not valid") }

        let token: String
        do {
            token = try settings.readToken()
        } catch {
            // The error names the file's path, never its content; the log gets neither.
            throw Transport(error: .unreachable(error.localizedDescription), logText: "couldn't read the token file")
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 10
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(Self.clientProtocol, forHTTPHeaderField: Self.protocolHeader)
        // Never over plain http to another host, whatever the provider says.
        if owner, OwnerKey.mayCarry(url), let key = ownerKey?() {
            request.setValue(key, forHTTPHeaderField: Self.ownerKeyHeader)
        }
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let result: (Data, URLResponse)
        do {
            result = try await session.data(for: request, delegate: NoRedirectDelegate.shared)
        } catch let error as URLError {
            // A TLS error's text names the host: the log gets the code only. A request
            // cancelled by a source swap is no failure.
            throw Transport(error: .unreachable(error.localizedDescription),
                            logText: error.code == .cancelled ? nil : "request failed (URLError \(error.code.rawValue))")
        } catch {
            throw QueueError.unreachable("the request failed")
        }
        let (data, response) = result
        guard let http = response as? HTTPURLResponse else {
            throw QueueError.unreachable("bad response from the Pond")
        }
        switch http.statusCode {
        case 200..<300:
            do {
                return try JSONDecoder().decode(T.self, from: data)
            } catch {
                throw QueueError.unreachable("bad response from the Pond")
            }
        case 300..<400:
            throw QueueError.unreachable("the Pond answered with a redirect (\(http.statusCode)); not following it")
        case 401:
            throw QueueError.unauthorized
        case 404:
            throw QueueError.notFound
        default:
            let body = try? JSONDecoder().decode(ErrorBody.self, from: data)
            if http.statusCode == 409, body?.error == "ask was corrected", let rev = body?.rev, let hash = body?.hash {
                throw QueueError.corrected(rev: rev, hash: hash, acceptedRev: body?.acceptedRev)
            }
            if http.statusCode == 403, body?.error == "unknown owner key" {
                throw QueueError.ownerKeyRefused
            }
            throw QueueError.rejected(
                status: http.statusCode,
                error: body?.error ?? "HTTP \(http.statusCode)",
                details: body?.details ?? [])
        }
    }
}
