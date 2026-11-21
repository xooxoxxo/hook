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
    /// With "requirements_unmet" (Pond 1.3.0): what the owner's Done still waits for.
    let left: [PondRequirement]?
    /// With "waiting_for_steps": when the wait ends, and the question's step path.
    let until: String?
    let path: String?
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

/// The mailbox service as a `QueueSource`. Credentials are read on every request,
/// never retained between calls. Synchronous token reads run on `KeychainQueue`.
public struct MailboxClient: QueueSource {
    /// A local Pond can become reachable just after the app starts. Wait for that
    /// connection, but bound the whole request (including the wait and response).
    /// Reuse the session across polls; callers can still inject their own session.
    public static let defaultSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 12
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        return URLSession(configuration: configuration)
    }()

    /// The session for the owner's writes (every method but GET): 30 s, so a slow network
    /// doesn't fail a reply the Pond would have taken. Background polls keep 10 s.
    public static let defaultWriteSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForRequest = writeTimeout
        configuration.timeoutIntervalForResource = writeTimeout + 2
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        return URLSession(configuration: configuration)
    }()

    public static let pollTimeout: TimeInterval = 10
    public static let writeTimeout: TimeInterval = 30

    /// A GET is a poll or a read (10 s); anything else is a write the owner started (30 s).
    public static func timeout(for method: String) -> TimeInterval {
        method == "GET" ? pollTimeout : writeTimeout
    }

    /// What every request says this client reads: revision histories (Pond 1.1.0; without it a
    /// corrected ask is served as a stub), and from 6 choice objects (Pond 1.4.0; below 6 an ask
    /// with one is served with labels only).
    public static let protocolHeader = "X-Hook-Protocol"
    public static let clientProtocol = "6"
    /// The owner key's header, sent on owner acts while this Mac's key is approved.
    public static let ownerKeyHeader = "X-Hook-Owner-Key"

    public let settings: MailboxSettings
    private let session: URLSession
    private let writeSession: URLSession
    /// The Mac's retry of a write that failed on the network; nil sends each write once.
    private let retry: PondRetryPolicy?
    /// The newest event per ask this client read, the baseline of a "maybe sent" check.
    private let seen = SeenEvents()
    /// Told how each request ended (an HTTP answer or a URLError code), for `LocalNetworkGate`.
    private let onOutcome: (@Sendable (PondOutcome) -> Void)?
    /// This client's last logged failure, so a Pond that stays down is logged once, not on every poll.
    private let failures = FailureLog()
    /// Read on each owner act, never stored: it returns this Mac's key only while the Pond
    /// has approved it (`OwnerKeyVault.approvedKey`). Async: it reads the Keychain on
    /// `KeychainQueue`, which may be waiting on a prompt.
    private let ownerKey: (@Sendable () async throws -> String?)?
    private let ownerStatusKey: (@Sendable () async throws -> String?)?
    private let tokenSource: any TokenSource
    private let keychain: KeychainQueue
    private let transport: (@Sendable (URLRequest) async throws -> (Data, URLResponse))?

    public init(settings: MailboxSettings, session: URLSession = MailboxClient.defaultSession,
                ownerKey: (@Sendable () async -> String?)? = nil, retry: PondRetryPolicy? = nil,
                onOutcome: (@Sendable (PondOutcome) -> Void)? = nil) {
        self.init(settings: settings, session: session, tokenSource: nil, ownerKey: ownerKey, retry: retry,
                  onOutcome: onOutcome)
    }

    /// An injected source defaults to HTTPS. FileTokenSource retains legacy HTTP support.
    /// Phone callers use `OwnerKeyFlow.authenticatedProvider`: read failures stop owner acts
    /// before any request is sent, rather than downgrading to bearer-only authentication.
    public init(settings: MailboxSettings, session: URLSession = MailboxClient.defaultSession,
                tokenSource: (any TokenSource)?, ownerKey: (@Sendable () async throws -> String?)? = nil,
                keychain: KeychainQueue = .shared,
                ownerStatusKey: (@Sendable () async throws -> String?)? = nil,
                transport: (@Sendable (URLRequest) async throws -> (Data, URLResponse))? = nil,
                writeSession: URLSession? = nil, retry: PondRetryPolicy? = nil,
                onOutcome: (@Sendable (PondOutcome) -> Void)? = nil) {
        self.onOutcome = onOutcome
        self.settings = settings
        self.session = session
        // An injected session carries the writes too, unless a write session is given.
        self.writeSession = writeSession ?? (session === MailboxClient.defaultSession ? MailboxClient.defaultWriteSession : session)
        self.retry = retry
        self.ownerKey = ownerKey
        self.tokenSource = tokenSource ?? FileTokenSource(path: settings.tokenFile)
        self.keychain = keychain
        self.transport = transport
        self.ownerStatusKey = ownerStatusKey
    }

    public init(baseURL: URL, tokenFile: String, context: String,
                session: URLSession = MailboxClient.defaultSession) {
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
        let detail: AskDetail = try await send("GET", "asks/\(id)")
        seen.note(detail)
        return detail
    }

    /// The Pond dedupes a post by context and title, so a resend can't make a second ask.
    public func post(project: String, instructable: Data) async throws -> PostResult {
        let body = Self.postBody(project: project, context: settings.context, instructable: instructable)
        return try await send("POST", "asks", body: body, write: .resend)
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
            let response: BugPostResponse = try await send("POST", "asks", body: body, owner: true, write: .resend)
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
                                                    owner: true,
                                                    write: .check(id, .status(verdict == .done ? "done" : "dismissed")))
        return response.item
    }

    public func reply(_ id: String, text: String) async throws -> WireItem {
        let response: ItemResponse = try await send(
            "POST", "asks/\(id)/reply", body: Self.encode(["text": text]), owner: true,
            write: .check(id, .event(kind: "reply", text: text.trimmingCharacters(in: .whitespacesAndNewlines))))
        return response.item
    }

    /// A message to the posting session (Pond 1.2.0): the reply route with `kind: "message"`.
    /// The text goes as typed. A closed ask or the 50-message cap answers 409, a secret-like
    /// text 400 (`MessageText.refusal` words both).
    public func message(_ id: String, text: String) async throws -> WireItem {
        let response: ItemResponse = try await send("POST", "asks/\(id)/reply",
                                                    body: Self.encode(["text": text, "kind": "message"]), owner: true,
                                                    write: .check(id, .event(kind: "message", text: text)))
        return response.item
    }

    /// The owner's tick changes as step ids (Pond 1.3.0), with the owner key and the revision
    /// shown, like answers. Only ids go: never a step's text.
    public func progress(_ id: String, tick: [String], untick: [String], stamp: RevisionStamp?) async throws -> WireItem {
        var body: [String: JSONValue] = ["tick": .array(tick.map(JSONValue.string)),
                                         "untick": .array(untick.map(JSONValue.string))]
        Self.add(stamp, to: &body)
        let response: ItemResponse = try await send("POST", "asks/\(id)/progress", body: JSONValue.object(body).data(),
                                                    owner: true, write: .resend)
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
                                                        owner: true, write: .resend)
            return response.item
        } catch QueueError.rejected(let status, _, _) where status == 409 {
            throw QueueError.askClosed
        }
    }

    /// Takes back a Done or Skip: always `actor: "owner"`. The mailbox returns an open
    /// ask unchanged.
    public func reopen(_ id: String) async throws -> WireItem {
        let response: ItemResponse = try await send("POST", "asks/\(id)/reopen", body: Self.encode(["actor": "owner"]),
                                                    owner: true, write: .resend)
        return response.item
    }

    /// The owner accepted this revision (Pond 1.1.0; always needs the owner key).
    public func accept(_ id: String, stamp: RevisionStamp) async throws -> WireItem {
        var body: [String: JSONValue] = [:]
        Self.add(stamp, to: &body)
        let response: ItemResponse = try await send("POST", "asks/\(id)/accept", body: JSONValue.object(body).data(),
                                                    owner: true, write: .resend)
        return response.item
    }

    /// A problem report on one step (by its id), bound to the revision shown (Pond 1.1.0;
    /// always needs the owner key).
    public func problem(_ id: String, stepID: String, stamp: RevisionStamp, note: String) async throws -> WireItem {
        var body: [String: JSONValue] = ["step": .string(stepID), "note": .string(note)]
        Self.add(stamp, to: &body)
        let response: ItemResponse = try await send("POST", "asks/\(id)/problems", body: JSONValue.object(body).data(),
                                                    owner: true, write: .check(id, .problem(stepID: stepID, note: note)))
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

    /// Revokes one device, authenticated with this device's approved owner key.
    public func revokeOwnerKey(_ id: String) async throws {
        let _: JSONValue = try await send("POST", "owner/revoke", body: Self.encode(["id": id]), owner: true)
    }

    /// `POST /owner/revoke-request` (`ownerRevokeRequest`): asks the owner, on Telegram, to revoke
    /// one device. The Pond token alone, so a Mac without a working key can ask; only the owner's tap
    /// revokes. 404 (unknown key) and 409 (already revoked, or another request pending) are answers
    /// the caller shows, not failures.
    public func requestRevoke(_ id: String) async throws -> RevokeRequest {
        try await send("POST", "owner/revoke-request", body: Self.encode(["id": id]), expected: [404, 409, 429, 502])
    }

    /// `GET /owner/revoke-request/{id}`: pending, approved, rejected or expired.
    public func revokeRequest(_ id: String) async throws -> RevokeRequest {
        try await send("GET", "owner/revoke-request/\(id)", expected: [404])
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

    /// `GET /version`: the Pond's version and its `features` list. A Pond from before `/version`
    /// answers 404, which counts as protocol 1 with no list.
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

    /// How an owner's write may be retried after a network failure (`PondRetryPolicy`).
    enum Write {
        /// Resending changes nothing the owner or the session sees.
        case resend
        /// Read the ask `id` and look for the write before any resend.
        case check(String, WriteLanding)

        var askID: String? { if case .check(let id, _) = self { return id } else { return nil } }
        var landing: WriteLanding { if case .check(_, let landing) = self { return landing } else { return .resend } }
    }

    /// `perform`, with a failure written to Hook's log as `error type=Pond status=… route=…`:
    /// the route is `path` cut to its template, and the message is a fixed phrase, a Pond
    /// error phrase or a URLError code, never an id, a title, the host or the token. A status
    /// in `expected` is an answer the caller handles, not a failure. A transport failure is
    /// followed by a `timing` line.
    ///
    /// With a retry policy, a `write` that failed on the network waits and goes again: at
    /// once when it never left this Mac, and after reading the ask when it may have reached
    /// the Pond, so a reply or a message the Pond already has is never sent twice. A refusal
    /// (any 4xx) is final.
    private func send<T: Decodable>(
        _ method: String,
        _ path: String,
        query: [URLQueryItem] = [],
        body: Data? = nil,
        owner: Bool = false,
        expected: Set<Int> = [],
        write: Write? = nil
    ) async throws -> T {
        let clock = ContinuousClock()
        let began = clock.now
        let startDate = Date()
        let baseline = write?.askID.flatMap(seen.baseline)
        var retries = 0
        var waiting = false
        var needsCheck = false
        var lastError = QueueError.unreachable("the request failed")
        func finish() { if waiting, let retry { retry.onWaiting(write?.askID, false) } }

        while true {
            if needsCheck, let id = write?.askID {
                needsCheck = false
                if let detail: AskDetail = try? await perform("GET", "asks/\(id)", query: [], body: nil, owner: false) {
                    seen.note(detail)
                    if write?.landing.landed(in: detail, after: baseline, since: startDate) == true,
                       let found = Self.landedValue(T.self, detail) {
                        HookLog.error("Pond", "write already on the Pond; not resent", route: path)
                        failures.clear()
                        finish()
                        return found
                    }
                } else {
                    // The ask couldn't be read, so whether the write landed is still unknown.
                    guard let retry, retries < retry.delays.count, clock.now - began < retry.deadline else {
                        finish(); throw lastError
                    }
                    if !waiting { waiting = true; retry.onWaiting(write?.askID, true) }
                    do { try await retry.sleep(retry.delays[retries]) } catch { finish(); throw lastError }
                    retries += 1
                    needsCheck = true
                    continue
                }
            }

            let certainty: DeliveryCertainty?
            do {
                let value: T = try await perform(method, path, query: query, body: body, owner: owner)
                failures.clear()
                finish()
                return value
            } catch let failure as Transport {
                if let text = failure.logText {
                    log(status: nil, path: path, message: text, force: method != "GET",
                        timing: (method, retries + 1, failure.timing))
                }
                certainty = failure.certainty
                lastError = failure.error
            } catch let error as QueueError {
                let (status, message) = Self.logged(error)
                if let status, expected.contains(status) { finish(); throw error }
                log(status: status, path: path, message: message, force: method != "GET", timing: nil)
                certainty = status.flatMap(PondRetryPolicy.certainty(forStatus:))
                lastError = error
            } catch {
                finish()
                throw error
            }

            guard let retry, let write, let certainty, retries < retry.delays.count,
                  clock.now - began < retry.deadline, !Task.isCancelled else {
                finish(); throw lastError
            }
            if certainty == .maybeSent, case .check = write { needsCheck = true }
            if !waiting { waiting = true; retry.onWaiting(write.askID, true) }
            do { try await retry.sleep(retry.delays[retries]) } catch { finish(); throw lastError }
            retries += 1
        }
    }

    /// The answer a write would have had, built from the ask that already holds it.
    private static func landedValue<T>(_ type: T.Type, _ detail: AskDetail) -> T? {
        ItemResponse(item: detail.item) as? T
    }

    private func log(status: Int?, path: String, message: String, force: Bool,
                     timing: (method: String, attempt: Int, timing: PondTiming?)?) {
        let route = RouteTemplate.template(path)
        guard failures.isNew("\(status.map(String.init) ?? "-") \(route) \(message)") || force else { return }
        HookLog.error("Pond", message, status: status, route: route)
        if let timing, let metrics = timing.timing {
            HookLog.record(.timing(type: "Pond", method: timing.method, route: route, attempt: timing.attempt,
                                   timeout: Int(Self.timeout(for: timing.method)), timing: metrics))
        }
    }

    /// The status and the log text for a failure. A Pond's own error is kept only when it is a
    /// short lowercase phrase like the spec's ("ask is closed"); anything else is `HTTP <status>`.
    static func logged(_ error: QueueError) -> (status: Int?, message: String) {
        switch error {
        case .unreachable(let reason): return (nil, reason)
        case .unauthorized, .tokenRejected: return (401, "unauthorized")
        case .notFound: return (404, "not found")
        case .corrected: return (409, "ask was corrected")
        case .ownerKeyRefused: return (403, "unknown owner key")
        case .askClosed: return (409, "ask is closed")
        case .requirementsUnmet: return (409, "requirements_unmet")
        case .stepsAdded: return (409, "steps_added")
        case .waitingForSteps: return (409, "waiting_for_steps")
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
        /// nil: a resend can't help.
        var certainty: DeliveryCertainty? = nil
        var timing: PondTiming? = nil
    }

    private func perform<T: Decodable>(
        _ method: String,
        _ path: String,
        query: [URLQueryItem],
        body: Data?,
        owner: Bool
    ) async throws -> T {
        let revokingOwnerKey = method == "POST" && path == "owner/revoke"
        if revokingOwnerKey { try Task.checkCancellation() }
        var components = URLComponents(
            url: settings.url.appending(path: path), resolvingAgainstBaseURL: false)
        if !query.isEmpty { components?.queryItems = query }
        guard let url = components?.url else { throw QueueError.unreachable("the Pond URL is not valid") }

        guard !tokenSource.requiresHTTPS || (url.scheme?.lowercased() == "https" && url.host != nil && url.user == nil && url.password == nil) else {
            throw QueueError.unreachable("The Pond token needs a valid URL that starts with https.")
        }
        let token: String
        do {
            let source = tokenSource
            token = try await keychain.run { try source.readToken() }
        } catch {
            // File source errors preserve the Mac's path-based help; Keychain errors name
            // only the token. Logs contain neither paths nor credential values.
            throw Transport(error: .unreachable(error.localizedDescription), logText: "couldn't read the Pond token")
        }

        if revokingOwnerKey { try Task.checkCancellation() }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = Self.timeout(for: method)
        // The Pond serves HTTP/1.1 and HTTP/2 only: never try QUIC first.
        request.assumesHTTP3Capable = false
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(Self.clientProtocol, forHTTPHeaderField: Self.protocolHeader)
        // Never over plain http to another host, whatever the provider says.
        if owner, OwnerKey.mayCarry(url) {
            do {
                let provider = method == "GET" && path == "owner" ? (ownerStatusKey ?? ownerKey) : ownerKey
                if let key = try await provider?() { request.setValue(key, forHTTPHeaderField: Self.ownerKeyHeader) }
            } catch {
                throw QueueError.unreachable("Hook couldn't read its owner key from the Keychain. Unlock this device and try again.")
            }
        }
        // Device revocation always needs an approved owner key, even while the Pond
        // permits bearer-only owner acts. A stale UI approval must not downgrade it.
        if method == "POST", path == "owner/revoke",
           request.value(forHTTPHeaderField: Self.ownerKeyHeader)?.isEmpty != false {
            throw QueueError.ownerKeyRefused
        }
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        // OwnerKeyFlow cancels this task when its source attachment changes. Reads
        // above may ignore cancellation, so fence the destructive request at dispatch.
        if revokingOwnerKey { try Task.checkCancellation() }
        let result: (Data, URLResponse)
        let delegate = PondTaskDelegate()
        do {
            if let transport {
                result = try await transport(request)
            } else {
                result = try await (method == "GET" ? session : writeSession).data(for: request, delegate: delegate)
            }
        } catch let error as URLError {
            // Retain safe underlying codes, never descriptions, URLs or userInfo
            // text. A request cancelled by a source swap is no outage.
            if error.code != .cancelled { onOutcome?(.failed(error.code)) }
            let timing = transport == nil ? await delegate.awaitTiming() : nil
            throw Transport(error: .unreachable(PondTransportDiagnostics.message(for: error)),
                            logText: PondTransportDiagnostics.logMessage(for: error),
                            certainty: PondRetryPolicy.certainty(for: error, timing: timing), timing: timing)
        } catch {
            if transport != nil { throw error }
            throw QueueError.unreachable("the request failed")
        }
        let (data, response) = result
        onOutcome?(.answered)
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
            throw tokenSource.requiresHTTPS ? QueueError.tokenRejected : QueueError.unauthorized
        case 404:
            throw QueueError.notFound
        default:
            let body = try? JSONDecoder().decode(ErrorBody.self, from: data)
            if http.statusCode == 409, body?.error == "ask was corrected", let rev = body?.rev, let hash = body?.hash {
                throw QueueError.corrected(rev: rev, hash: hash, acceptedRev: body?.acceptedRev)
            }
            if http.statusCode == 409, body?.error == "requirements_unmet" {
                throw QueueError.requirementsUnmet(left: body?.left ?? [])
            }
            if http.statusCode == 409, body?.error == "steps_added", let rev = body?.rev, let hash = body?.hash {
                throw QueueError.stepsAdded(rev: rev, hash: hash)
            }
            if http.statusCode == 409, body?.error == "waiting_for_steps",
               let until = body?.until.flatMap(Timestamp.date) {
                throw QueueError.waitingForSteps(until: until)
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
