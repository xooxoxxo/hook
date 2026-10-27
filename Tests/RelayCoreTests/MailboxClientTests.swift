import Foundation
import Testing
@testable import RelayCore

/// Canned answers per fake host, so parallel tests never share a handler.
final class MailboxStubRegistry: @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest, Data) throws -> (status: Int, body: String)

    static let shared = MailboxStubRegistry()
    private let lock = NSLock()
    private var handlers: [String: Handler] = [:]
    private var seen: [String: (request: URLRequest, body: Data)] = [:]

    func register(_ host: String, _ handler: @escaping Handler) {
        lock.lock()
        defer { lock.unlock() }
        handlers[host] = handler
    }

    func answer(_ request: URLRequest, body: Data) throws -> (status: Int, body: String)? {
        let host = request.url?.host() ?? ""
        lock.lock()
        seen[host] = (request, body)
        let handler = handlers[host]
        lock.unlock()
        return try handler?(request, body)
    }

    func last(_ host: String) -> (request: URLRequest, body: Data)? {
        lock.lock()
        defer { lock.unlock() }
        return seen[host]
    }
}

final class MailboxStubProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            guard let url = request.url,
                  let answer = try MailboxStubRegistry.shared.answer(request, body: Self.body(of: request)),
                  let response = HTTPURLResponse(
                      url: url, statusCode: answer.status, httpVersion: "HTTP/1.1", headerFields: nil)
            else {
                client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
                return
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(answer.body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    /// URLSession hands a protocol the body as a stream, not as `httpBody`.
    private static func body(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

private let askID = "6f1c2b0e-8a1d-4c55-9a77-0d2f3c4b5a61"
private let itemJSON = """
    {"id":"\(askID)","source":"mailbox","title":"Rotate the key","status":"open",\
    "projectId":"Acme","lane":"work","created":"2026-10-11T09:30:00+00:00",\
    "updated":"2026-10-11T09:30:00+00:00","payload":{"why":"It expires Friday"}}
    """
private let rawInstructable = #"{"v":1,"title":"Rotate the key","steps":[{"do":"Open the vault"}]}"#

/// A client whose session only talks to the stub, for a host unique to the test.
private func makeClient(
    writeToken: Bool = true,
    _ handler: @escaping MailboxStubRegistry.Handler
) throws -> (client: MailboxClient, host: String) {
    let host = "mbx-" + UUID().uuidString.lowercased() + ".test"
    MailboxStubRegistry.shared.register(host, handler)
    let dir = FileManager.default.temporaryDirectory.appending(path: "relay-mbx-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let tokenFile = dir.appending(path: "mailbox-token")
    if writeToken { try Data("tok-example\n".utf8).write(to: tokenFile) }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MailboxStubProtocol.self]
    let client = MailboxClient(
        baseURL: try #require(URL(string: "http://\(host):8790")),
        tokenFile: tokenFile.path, context: "work",
        session: URLSession(configuration: configuration))
    return (client, host)
}

@Suite struct MailboxClientTests {
    @Test func listAsksForOpenAsksOfAnyAge() async throws {
        let (client, host) = try makeClient { _, _ in (200, #"{"items":[\#(itemJSON)]}"#) }
        let items = try await client.list()
        #expect(items.map(\.id) == [askID])
        #expect(items.first?.projectId == "Acme")
        let sent = try #require(MailboxStubRegistry.shared.last(host))
        #expect(sent.request.httpMethod == "GET")
        #expect(sent.request.url?.path() == "/asks")
        let query = URLComponents(url: try #require(sent.request.url), resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(query.contains(URLQueryItem(name: "status", value: "open")))
        #expect(query.contains(URLQueryItem(name: "days", value: "36500")))
        #expect(sent.request.value(forHTTPHeaderField: "Authorization") == "Bearer tok-example")
    }

    @Test func postSendsContextAndTheRawInstructable() async throws {
        let answer = #"{"item":\#(itemJSON),"openUrl":"http://127.0.0.1:47823/i/\#(askID)"}"#
        let (client, host) = try makeClient { _, _ in (201, answer) }
        let result = try await client.post(project: "Acme", instructable: Data(rawInstructable.utf8))
        #expect(result.item.id == askID)
        #expect(!result.deduped)
        #expect(result.openURL == "http://127.0.0.1:47823/i/\(askID)")
        let sent = try #require(MailboxStubRegistry.shared.last(host))
        #expect(sent.request.httpMethod == "POST")
        #expect(sent.request.url?.path() == "/asks")
        #expect(sent.request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let body = try JSONValue.parse(sent.body)
        #expect(body["project"] == .string("Acme"))
        #expect(body["context"] == .string("work"))
        let sentInstructable = try JSONValue.parse(Data(rawInstructable.utf8))
        #expect(body["instructable"] == sentInstructable)
    }

    @Test func resolveAndReplyActAsTheOwner() async throws {
        let (client, host) = try makeClient { _, _ in (200, #"{"item":\#(itemJSON)}"#) }
        _ = try await client.resolve(askID, verdict: .declined, note: "Not now")
        let resolve = try JSONValue.parse(try #require(MailboxStubRegistry.shared.last(host)).body)
        #expect(resolve == .object(["verdict": .string("declined"), "actor": .string("owner"), "note": .string("Not now")]))
        #expect(MailboxStubRegistry.shared.last(host)?.request.url?.path() == "/asks/\(askID)/resolve")

        _ = try await client.reply(askID, text: "choice: Yes")
        let reply = try JSONValue.parse(try #require(MailboxStubRegistry.shared.last(host)).body)
        #expect(reply == .object(["text": .string("choice: Yes")]))
        #expect(MailboxStubRegistry.shared.last(host)?.request.url?.path() == "/asks/\(askID)/reply")
    }

    @Test func reopenPostsAsTheOwner() async throws {
        let (client, host) = try makeClient { _, _ in (200, #"{"item":\#(itemJSON)}"#) }
        let item = try await client.reopen(askID)
        #expect(item.id == askID)
        let sent = try #require(MailboxStubRegistry.shared.last(host))
        #expect(sent.request.httpMethod == "POST")
        #expect(sent.request.url?.path() == "/asks/\(askID)/reopen")
        #expect(sent.request.value(forHTTPHeaderField: "Authorization") == "Bearer tok-example")
        #expect(try JSONValue.parse(sent.body) == .object(["actor": .string("owner")]))

        let (missing, _) = try makeClient { _, _ in (404, #"{"error":"not found"}"#) }
        await #expect(throws: QueueError.notFound) { try await missing.reopen(askID) }
        let (redirect, _) = try makeClient { _, _ in (302, "") }
        await #expect(throws: QueueError.self) { try await redirect.reopen(askID) }
    }

    @Test func recentlyClosedMergesDoneAndDismissed() async throws {
        let now = Date()
        func closed(_ id: String, _ status: String, _ ago: TimeInterval?) -> String {
            let completed = ago.map { #""\#(Timestamp.string(now.addingTimeInterval(-$0)))""# } ?? "null"
            return #"{"id":"\#(id)","title":"T \#(id)","status":"\#(status)","created":"2026-09-01T09:30:00+00:00","updated":"2026-09-01T09:30:00+00:00","completedAt":\#(completed),"payload":{}}"#
        }
        let done = [closed("d1", "done", 600), closed("d2", "done", 5 * 3600), closed("d3", "done", nil)]
        let dismissed = [closed("x1", "dismissed", 60),
                         #"{"id":"x2","title":"T","status":"dismissed","created":"2026-09-01T09:30:00+00:00","updated":"2026-09-01T09:30:00+00:00","completedAt":"yesterday","payload":{}}"#]
        let statuses = StatusLog()
        let (client, _) = try makeClient { request, _ in
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let status = query.first { $0.name == "status" }?.value ?? ""
            let days = query.first { $0.name == "days" }?.value ?? ""
            statuses.add(status + "/" + days)
            let items = status == "done" ? done : status == "dismissed" ? dismissed : []
            return (200, #"{"items":[\#(items.joined(separator: ","))]}"#)
        }
        let items = try await client.recentlyClosed(within: 3600)
        #expect(items.map(\.id) == ["x1", "d1"])
        #expect(statuses.all.sorted() == ["dismissed/14", "done/14"])
    }

    @Test func closedWithinSkipsOpenAndDuplicates() {
        let now = Date(timeIntervalSince1970: 1_791_000_000)
        func item(_ id: String, _ status: String, _ completed: String?) -> WireItem {
            WireItem(id: id, title: id, status: status, projectId: nil, created: "2026-10-01T00:00:00+00:00",
                     updated: "2026-10-01T00:00:00+00:00", payload: Payload(why: nil, cmd: nil, link: nil, instructable: nil),
                     completedAt: completed)
        }
        let stamp = Timestamp.string(now.addingTimeInterval(-10))
        let older = Timestamp.string(now.addingTimeInterval(-20))
        let result = MailboxClient.closedWithin(
            [item("a", "done", older), item("b", "open", stamp), item("a", "done", older), item("c", "dismissed", stamp)],
            interval: 60, now: now)
        #expect(result.map(\.id) == ["c", "a"])
    }

    @Test func mapsHTTPErrors() async throws {
        let (notFound, _) = try makeClient { _, _ in (404, #"{"error":"not found"}"#) }
        await #expect(throws: QueueError.notFound) { try await notFound.get(askID) }

        let (unauthorized, _) = try makeClient { _, _ in (401, #"{"error":"unauthorized"}"#) }
        await #expect(throws: QueueError.unauthorized) { try await unauthorized.list() }

        let details = #"{"error":"invalid instructable","details":["steps: must be a list of 1 to 20 steps"]}"#
        let (rejected, _) = try makeClient { _, _ in (400, details) }
        await #expect(throws: QueueError.rejected(
            status: 400, error: "invalid instructable", details: ["steps: must be a list of 1 to 20 steps"])) {
            try await rejected.post(project: "Acme", instructable: Data(#"{"v":1,"title":"x"}"#.utf8))
        }

        let (gateway, _) = try makeClient { _, _ in (502, "<html>bad gateway</html>") }
        await #expect(throws: QueueError.rejected(status: 502, error: "HTTP 502", details: [])) {
            try await gateway.list()
        }
    }

    @Test func redirectsAreRefusedAndMappedToUnreachable() async throws {
        let (redirecting, _) = try makeClient { _, _ in (302, "") }
        do {
            _ = try await redirecting.list()
            Issue.record("expected the redirect to be refused")
        } catch let QueueError.unreachable(reason) {
            #expect(reason.contains("redirect"))
        }
    }

    @Test func noRedirectDelegateDeclinesEveryRedirect() async throws {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let url = try #require(URL(string: "http://mbx.test/asks"))
        let task = session.dataTask(with: URLRequest(url: url))   // never resumed
        let response = try #require(HTTPURLResponse(
            url: url, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": "http://other.test/"]))
        let next = await NoRedirectDelegate().urlSession(
            session, task: task, willPerformHTTPRedirection: response,
            newRequest: URLRequest(url: try #require(URL(string: "http://other.test/"))))
        #expect(next == nil)
    }

    @Test func transportAndTokenProblemsAreUnreachable() async throws {
        let (down, _) = try makeClient { _, _ in throw URLError(.cannotConnectToHost) }
        await expectUnreachable { try await down.list() }

        let (garbled, _) = try makeClient { _, _ in (200, "not json") }
        await expectUnreachable { try await garbled.list() }

        let (noToken, host) = try makeClient(writeToken: false) { _, _ in (200, #"{"items":[]}"#) }
        await expectUnreachable { try await noToken.list() }
        #expect(MailboxStubRegistry.shared.last(host) == nil)   // nothing was sent without a token
    }

    @Test func postResultDecoding() throws {
        let plain = try JSONDecoder().decode(PostResult.self, from: Data(#"{"item":\#(itemJSON)}"#.utf8))
        #expect(!plain.deduped)
        #expect(plain.openURL == nil)
        let deduped = try JSONDecoder().decode(
            PostResult.self,
            from: Data(#"{"item":\#(itemJSON),"deduped":true,"openUrl":"http://127.0.0.1:47823/i/x"}"#.utf8))
        #expect(deduped.deduped)
        #expect(deduped.openURL == "http://127.0.0.1:47823/i/x")
    }

    @Test func mailboxHasNoChangeStream() async throws {
        let (client, _) = try makeClient { _, _ in (200, "{}") }
        #expect(await client.changes() == nil)
    }

    @Test func errorDescriptionsCarryNoSecrets() {
        #expect(QueueError.unauthorized.localizedDescription == "The mailbox rejected the token (check the token file)")
        #expect(QueueError.storeFailed("disk full").localizedDescription == "Couldn't save the queue: disk full")
        #expect(QueueError.rejected(status: 400, error: "invalid project", details: ["project: required"])
            .localizedDescription == "invalid project: project: required")
    }
}

private func expectUnreachable<T>(
    _ body: () async throws -> T,
    sourceLocation: SourceLocation = #_sourceLocation
) async {
    do {
        _ = try await body()
        Issue.record("expected QueueError.unreachable", sourceLocation: sourceLocation)
    } catch let error as QueueError {
        guard case .unreachable(let reason) = error else {
            Issue.record("expected .unreachable, got \(error)", sourceLocation: sourceLocation)
            return
        }
        #expect(!reason.contains("tok-example"), sourceLocation: sourceLocation)
    } catch {
        Issue.record("expected QueueError, got \(error)", sourceLocation: sourceLocation)
    }
}

/// Records the queries a stub saw, across URLSession's threads.
final class StatusLog: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [String] = []
    func add(_ value: String) {
        lock.lock()
        defer { lock.unlock() }
        seen.append(value)
    }
    var all: [String] {
        lock.lock()
        defer { lock.unlock() }
        return seen
    }
}

@Suite struct MailboxClientAnswerTests {
    @Test func answersPostOneBatch() async throws {
        let (client, host) = try makeClient { _, _ in (200, #"{"item":\#(itemJSON)}"#) }
        let item = try await client.answer(askID, answers: [
            Answers.entry(step: "3.2", picked: ["Staging"]), Answers.entry(step: "4", text: "EU"),
        ])
        #expect(item.id == askID)
        let sent = try #require(MailboxStubRegistry.shared.last(host))
        #expect(sent.request.httpMethod == "POST")
        #expect(sent.request.url?.path() == "/asks/\(askID)/answers")
        #expect(sent.request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(try JSONValue.parse(sent.body) == .object(["answers": .array([
            .object(["step": .string("3.2"), "picked": .array([.string("Staging")])]),
            .object(["step": .string("4"), "text": .string("EU")]),
        ])]))
    }

    @Test func closedInvalidAndUnknownAsks() async throws {
        let (closed, _) = try makeClient { _, _ in (409, #"{"error":"ask is closed"}"#) }
        await #expect(throws: QueueError.askClosed) {
            try await closed.answer(askID, answers: [Answers.entry(step: "1", text: "x")])
        }
        let (invalid, _) = try makeClient { _, _ in
            (400, #"{"error":"invalid answers","details":["answers[0].step: no question at this step"]}"#)
        }
        await #expect(throws: QueueError.rejected(status: 400, error: "invalid answers",
                                                  details: ["answers[0].step: no question at this step"])) {
            try await invalid.answer(askID, answers: [Answers.entry(step: "9", text: "x")])
        }
        let (missing, _) = try makeClient { _, _ in (404, #"{"error":"not found"}"#) }
        await #expect(throws: QueueError.notFound) {
            try await missing.answer(askID, answers: [Answers.entry(step: "1", text: "x")])
        }
    }
}
