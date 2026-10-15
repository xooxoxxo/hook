import Foundation
import Testing
@testable import RelayCore

private let port = 47823
private let goodToken = String(repeating: "ab", count: 32)
private let goodHost = "127.0.0.1:47823"
private let unknownID = "6f1c2b0e-8a1d-4c55-9a77-0d2f3c4b5a61"

private func askBody(title: String = "Rotate the key", project: String = "Acme") -> String {
    #"{"project":"\#(project)","context":"work","instructable":{"v":1,"title":"\#(title)","steps":[{"do":"Open the vault"}]}}"#
}

private struct Harness {
    let api: LocalAPI
    let queue: LocalQueue

    func send(
        _ method: String,
        _ target: String,
        body: String = "",
        host: String? = goodHost,
        auth: String? = "Bearer " + goodToken,
        headers extra: [String: String] = [:]
    ) async -> HTTPResponse {
        let parts = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        var query: [String: String] = [:]
        if parts.count > 1 {
            for pair in parts[1].split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                query[String(kv[0])] = kv.count > 1 ? String(kv[1]) : ""
            }
        }
        var headers = extra
        if let host { headers["host"] = host }
        if let auth { headers["authorization"] = auth }
        let request = HTTPRequest(
            method: method, path: String(parts[0]), query: query, headers: headers, body: Data(body.utf8))
        return await api.handle(request)
    }

    /// Posts a valid ask and returns its id.
    func post(title: String = "Rotate the key") async throws -> String {
        let response = await send("POST", "/asks", body: askBody(title: title))
        #expect(response.status == 201)
        return try #require(json(response)["item"]?["id"]?.stringValue)
    }
}

private func harness(token: String? = goodToken) async throws -> Harness {
    let dir = FileManager.default.temporaryDirectory.appending(path: "relay-api-\(UUID().uuidString)")
    let queue = LocalQueue(directory: dir, keepDays: 14)
    _ = try await queue.open()
    return Harness(api: LocalAPI(queue: queue, port: port, token: { token }), queue: queue)
}

private func json(_ response: HTTPResponse) throws -> JSONValue {
    try JSONValue.parse(response.body)
}

private func error(_ response: HTTPResponse) -> String? {
    (try? JSONValue.parse(response.body))?["error"]?.stringValue
}

private func details(_ response: HTTPResponse) -> [String] {
    guard case .array(let values)? = (try? JSONValue.parse(response.body))?["details"] else { return [] }
    return values.compactMap(\.stringValue)
}

@Suite struct LocalAPIGateTests {
    @Test(arguments: ["127.0.0.1:47823", "localhost:47823", "LOCALHOST:47823", "LocalHost:47823"])
    func allowedHosts(_ host: String) async throws {
        let h = try await harness()
        #expect(await h.send("GET", "/asks", host: host).status == 200)
    }

    @Test(arguments: [
        nil, "evil.example:47823", "127.0.0.1:47824", "127.0.0.1", "[::1]:47823", "localhost.:47823",
        "127.0.0.1:47823,127.0.0.1:47823",
    ] as [String?])
    func refusedHosts(_ host: String?) async throws {
        let h = try await harness()
        let response = await h.send("GET", "/asks", host: host)
        #expect(response.status == 403)
        #expect(error(response) == "forbidden")
    }

    @Test func hostIsCheckedBeforeTheRoute() async throws {
        let h = try await harness()
        #expect(await h.send("GET", "/nope", host: "evil.example:47823").status == 403)
    }

    @Test func browsersAreRefused() async throws {
        let h = try await harness()
        let origin = await h.send("GET", "/asks", headers: ["origin": "https://example.com"])
        #expect(origin.status == 403)
        #expect(error(origin) == "forbidden")
        #expect(await h.send("GET", "/asks", headers: ["Origin": "null"]).status == 403)
        for site in ["cross-site", "same-site", "same-origin"] {
            #expect(await h.send("GET", "/asks", headers: ["sec-fetch-site": site]).status == 403)
        }
        #expect(await h.send("GET", "/asks", headers: ["sec-fetch-site": "none"]).status == 200)
        // No CORS headers, ever.
        #expect(!origin.headers.keys.contains { $0.lowercased().hasPrefix("access-control") })
    }

    @Test func unknownRoutesAre404BeforeAuth() async throws {
        let h = try await harness()
        for (method, path) in [
            ("GET", "/nope"), ("DELETE", "/asks"), ("GET", "/health"), ("GET", "/asks/"),
            ("POST", "/asks/\(unknownID)/reply"), ("POST", "/asks/\(unknownID)/ack"), ("GET", "/asks/\(unknownID)/resolve"),
        ] {
            let response = await h.send(method, path, auth: nil)
            #expect(response.status == 404, "\(method) \(path)")
            #expect(error(response) == "not found")
        }
    }

    @Test func auth() async throws {
        let h = try await harness()
        for header in [nil, "Bearer nope", "Bearer " + goodToken + "x", "Basic " + goodToken, goodToken] as [String?] {
            let response = await h.send("GET", "/asks", auth: header)
            #expect(response.status == 401)
            #expect(error(response) == "unauthorized")
        }
        #expect(await h.send("GET", "/asks").status == 200)

        let noToken = try await harness(token: nil)
        #expect(await noToken.send("GET", "/asks").status == 401)
    }

    @Test func responsesAreJSONAndUncached() async throws {
        let h = try await harness()
        for response in [await h.send("GET", "/asks"), await h.send("GET", "/nope")] {
            #expect(response.headers["Content-Type"] == "application/json")
            #expect(response.headers["Cache-Control"] == "no-store")
        }
    }

    @Test func lastSeenRecordsAuthenticatedClients() async throws {
        let h = try await harness()
        _ = await h.send("GET", "/asks", auth: nil, headers: ["x-relay-client": "mcp/0.4.0"])
        #expect(await h.api.lastSeen()["mcp"] == nil)
        _ = await h.send("GET", "/asks", headers: ["X-Relay-Client": "cli/0.4.0"])
        _ = await h.send("GET", "/asks", headers: ["x-relay-client": "browser/1"])
        let seen = await h.api.lastSeen()
        #expect(seen["cli"] != nil)
        #expect(seen["mcp"] == nil)
        #expect(seen.count == 1)
    }
}

@Suite struct LocalAPIPostTests {
    @Test func postCreatesWithEveryWireKeyAndOpenURL() async throws {
        let h = try await harness()
        let response = await h.send("POST", "/asks", body: askBody())
        #expect(response.status == 201)
        let body = try json(response)
        guard case .object(let item)? = body["item"] else {
            Issue.record("no item")
            return
        }
        #expect(Set(item.keys) == [
            "id", "source", "title", "status", "priority", "pinned", "rolling", "payloadType", "payload", "links",
            "created", "updated", "anchor", "recurrence", "snoozeUntil", "projectId", "lane", "completedAt",
        ])
        let id = try #require(item["id"]?.stringValue)
        #expect(item["completedAt"] == .null)
        #expect(item["projectId"] == .string("Acme"))
        #expect(item["payload"]?["key"]?.stringValue?.count == 16)
        #expect(item["created"]?.stringValue?.hasSuffix("+00:00") == true)
        #expect(body["openUrl"] == .string("http://127.0.0.1:47823/i/\(id)"))
        #expect(body["deduped"] == nil)
    }

    @Test func dedupedPostAnswers200() async throws {
        let h = try await harness()
        let id = try await h.post()
        let again = await h.send("POST", "/asks", body: askBody())
        #expect(again.status == 200)
        let body = try json(again)
        #expect(body["deduped"] == .bool(true))
        #expect(body["item"]?["id"] == .string(id))
        #expect(body["openUrl"] == .string("http://127.0.0.1:47823/i/\(id)"))
    }

    @Test func emptyBodyCountsAsAnEmptyObject() async throws {
        let h = try await harness()
        let response = await h.send("POST", "/asks", body: "")
        #expect(response.status == 400)
        #expect(error(response) == "missing fields")
        let nullInstructable = await h.send("POST", "/asks", body: #"{"project":"Acme","instructable":null}"#)
        #expect(error(nullInstructable) == "missing fields")
    }

    @Test(arguments: ["[1]", #""text""#, "42", "{", "not json", #"{"project":"Acme","instructable":"\ud800"}"#])
    func invalidJSON(_ body: String) async throws {
        let h = try await harness()
        let response = await h.send("POST", "/asks", body: body)
        #expect(response.status == 400)
        #expect(error(response) == "invalid json")
    }

    @Test func invalidInstructableCarriesFieldPaths() async throws {
        let h = try await harness()
        let raw = #"{"v":1,"title":"Rotate the key","token":"ghp_example"}"#
        let response = await h.send("POST", "/asks", body: #"{"project":"Acme","instructable":\#(raw)}"#)
        #expect(response.status == 400)
        #expect(error(response) == "invalid instructable")
        guard case .failure(let failure) = Validator.validate(try JSONValue.parse(Data(raw.utf8))) else {
            Issue.record("the fixture should be invalid")
            return
        }
        #expect(details(response).sorted() == failure.errors.sorted())
        #expect(!String(decoding: response.body, as: UTF8.self).contains("ghp_example"))
    }

    @Test func invalidProject() async throws {
        let h = try await harness()
        let ins = #"{"v":1,"title":"Rotate the key","steps":[{"do":"Open the vault"}]}"#
        let missing = await h.send("POST", "/asks", body: #"{"instructable":\#(ins)}"#)
        #expect(missing.status == 400)
        #expect(error(missing) == "invalid project")
        #expect(details(missing) == ["project: required"])
        let tooLong = await h.send("POST", "/asks", body: askBody(project: String(repeating: "a", count: 61)))
        #expect(error(tooLong) == "invalid project")
    }

    @Test func queueFullButDedupeStillAnswers() async throws {
        let h = try await harness()
        for index in 0..<LocalQueue.maxOpen {
            let response = await h.send("POST", "/asks", body: askBody(title: "Ask \(index)"))
            #expect(response.status == 201)
        }
        let full = await h.send("POST", "/asks", body: askBody(title: "One too many"))
        #expect(full.status == 429)
        #expect(error(full) == "queue full")
        let dedupe = await h.send("POST", "/asks", body: askBody(title: "Ask 0"))
        #expect(dedupe.status == 200)
    }
}

@Suite struct LocalAPIReadTests {
    @Test func listFiltersByStatus() async throws {
        let h = try await harness()
        let open = try await h.post(title: "Still open")
        let closed = try await h.post(title: "Finished")
        #expect(await h.send("POST", "/asks/\(closed)/resolve", body: #"{"verdict":"done"}"#).status == 200)

        func ids(_ target: String) async throws -> Set<String> {
            let response = await h.send("GET", target)
            #expect(response.status == 200)
            guard case .array(let items)? = try json(response)["items"] else { return [] }
            return Set(items.compactMap { $0["id"]?.stringValue })
        }
        #expect(try await ids("/asks") == [open])
        #expect(try await ids("/asks?status=open&days=14") == [open])
        #expect(try await ids("/asks?status=done") == [closed])
        #expect(try await ids("/asks?status=dismissed").isEmpty)
        #expect(try await ids("/asks?status=all&days=36500") == [open, closed])
    }

    @Test(arguments: ["status=closed", "days=-1", "days=36501", "days=abc", "days="])
    func listRejectsBadQueries(_ query: String) async throws {
        let h = try await harness()
        let response = await h.send("GET", "/asks?\(query)")
        #expect(response.status == 400)
        #expect(error(response) == "invalid query")
    }

    @Test func getOneAsk() async throws {
        let h = try await harness()
        let id = try await h.post()
        let response = await h.send("GET", "/asks/\(id)")
        #expect(response.status == 200)
        let body = try json(response)
        #expect(body["item"]?["id"] == .string(id))
        guard case .array(let events)? = body["events"] else {
            Issue.record("no events")
            return
        }
        #expect(events.map { $0["kind"] } == [.string("posted")])
        #expect(events.first?["actor"] == .string("session"))

        #expect(await h.send("GET", "/asks/\(id.uppercased())").status == 200)
        #expect(error(await h.send("GET", "/asks/\(unknownID)")) == "not found")
        #expect(await h.send("GET", "/asks/not-a-uuid").status == 404)
    }

    @Test func eventsPageWithEpoch() async throws {
        let h = try await harness()
        let id = try await h.post()
        #expect(await h.send("POST", "/asks/\(id)/resolve", body: #"{"verdict":"declined"}"#).status == 200)

        let all = try json(await h.send("GET", "/events"))
        #expect(all["epoch"] == .string(await h.queue.epoch))
        guard case .array(let events)? = all["events"] else {
            Issue.record("no events")
            return
        }
        #expect(events.map { $0["kind"] } == [.string("posted"), .string("declined")])
        // Every event key is present, as on a mailbox: no text is an explicit null.
        #expect(events.first?["text"] == .null)
        #expect(all["next"] == events.last?["seq"])

        let page = try json(await h.send("GET", "/events?after=1&limit=1"))
        guard case .array(let one)? = page["events"] else {
            Issue.record("no page")
            return
        }
        #expect(one.count == 1)
        #expect(one.first?["seq"] == .int(2))
        #expect(page["next"] == .int(2))

        let empty = try json(await h.send("GET", "/events?after=99"))
        #expect(empty["events"] == .array([]))
        #expect(empty["next"] == .int(99))
    }

    @Test(arguments: ["after=-1", "after=x", "limit=0", "limit=1001", "limit=x"])
    func eventsRejectBadQueries(_ query: String) async throws {
        let h = try await harness()
        let response = await h.send("GET", "/events?\(query)")
        #expect(response.status == 400)
        #expect(error(response) == "invalid query")
    }
}

@Suite struct LocalAPIResolveTests {
    @Test func doneAndDeclined() async throws {
        let h = try await harness()
        let first = try await h.post(title: "First")
        let done = await h.send("POST", "/asks/\(first)/resolve", body: #"{"verdict":"done","note":"Rotated\nall keys"}"#)
        #expect(done.status == 200)
        #expect(try json(done)["item"]?["status"] == .string("done"))
        let detail = try json(await h.send("GET", "/asks/\(first)"))
        guard case .array(let events)? = detail["events"] else {
            Issue.record("no events")
            return
        }
        #expect(events.last?["kind"] == .string("resolved"))
        #expect(events.last?["actor"] == .string("session"))
        #expect(events.last?["text"] == .string("Rotated\nall keys"))

        let second = try await h.post(title: "Second")
        let declined = await h.send("POST", "/asks/\(second)/resolve", body: #"{"verdict":"declined","actor":"session"}"#)
        #expect(try json(declined)["item"]?["status"] == .string("dismissed"))
    }

    @Test func resolvingAFinishedAskChangesNothing() async throws {
        let h = try await harness()
        let id = try await h.post()
        let first = try json(await h.send("POST", "/asks/\(id)/resolve", body: #"{"verdict":"done"}"#))
        let eventsBefore = await h.queue.events(after: 0, limit: 1000).events.count
        let again = await h.send("POST", "/asks/\(id)/resolve", body: #"{"verdict":"declined"}"#)
        #expect(again.status == 200)
        #expect(try json(again)["item"] == first["item"])
        #expect(await h.queue.events(after: 0, limit: 1000).events.count == eventsBefore)
    }

    @Test func actorRules() async throws {
        let h = try await harness()
        let id = try await h.post()
        let owner = await h.send("POST", "/asks/\(id)/resolve", body: #"{"verdict":"done","actor":"owner"}"#)
        #expect(owner.status == 403)
        #expect(error(owner) == "owner actions are app-only")
        for actor in [#""bob""#, "5", "true", #"["session"]"#] {
            let response = await h.send("POST", "/asks/\(id)/resolve", body: #"{"verdict":"done","actor":\#(actor)}"#)
            #expect(response.status == 400)
            #expect(error(response) == "invalid actor")
        }
        for (index, actor) in ["null", #""""#].enumerated() {
            let other = try await h.post(title: "Actor \(index)")
            let response = await h.send("POST", "/asks/\(other)/resolve", body: #"{"verdict":"done","actor":\#(actor)}"#)
            #expect(response.status == 200)
        }
    }

    @Test func verdictIsCheckedFirst() async throws {
        let h = try await harness()
        for body in ["", #"{"verdict":"maybe","actor":"owner"}"#, #"{"verdict":1}"#] {
            let response = await h.send("POST", "/asks/\(unknownID)/resolve", body: body)
            #expect(response.status == 400)
            #expect(error(response) == "invalid verdict")
        }
        let unknown = await h.send("POST", "/asks/\(unknownID)/resolve", body: #"{"verdict":"done"}"#)
        #expect(unknown.status == 404)
        #expect(await h.send("POST", "/asks/not-a-uuid/resolve", body: #"{"verdict":"done"}"#).status == 404)
    }

    @Test func invalidNote() async throws {
        let h = try await harness()
        let id = try await h.post()
        for note in [String(repeating: "a", count: 301), "sk-ant-example", "zero\u{200B}width"] {
            let body = String(decoding: JSONValue.object(["verdict": .string("done"), "note": .string(note)]).data(), as: UTF8.self)
            let response = await h.send("POST", "/asks/\(id)/resolve", body: body)
            #expect(response.status == 400)
            #expect(error(response) == "invalid note")
            #expect(!details(response).isEmpty)
        }
        let open = try json(await h.send("GET", "/asks/\(id)"))
        #expect(open["item"]?["status"] == .string("open"))
    }
}

@Suite struct LocalAPIHardeningTests {
    @Test func oversizeBodyReachingHandleIs413() async throws {
        let h = try await harness()
        let big = String(repeating: "a", count: RequestFraming.maxBody + 1)
        let response = await h.send("POST", "/asks", body: big)
        #expect(response.status == 413)
        #expect(try json(response)["error"]?.stringValue == "body too large")
    }

    private struct Unencodable: Encodable { var x = Double.nan }

    @Test func encodeFailureIsNilNotNull() {
        #expect(LocalAPI.value(Unencodable()) == nil)
        #expect(LocalAPI.values([Unencodable()]) == nil)
        #expect(LocalAPI.value(["a": 1]) != nil)
        #expect(LocalAPI.values([1, 2])?.count == 2)
    }
}
