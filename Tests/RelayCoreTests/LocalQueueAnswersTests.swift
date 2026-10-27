import Foundation
import Testing
@testable import RelayCore

private let askWithQuestions = #"""
{"v":1,"title":"Ship the Atlas release","steps":[
  {"do":"Pick the deploy target","question":{"prompt":"Which environment?","choices":["Staging","Prod"]}},
  {"do":"Name the region","question":{"prompt":"Which region?"}},
  {"do":"Open the dashboard"}]}
"""#

private func post(_ queue: LocalQueue) async throws -> LocalItem {
    try await queue.post(project: .string("Acme"), instructable: JSONValue.parse(Data(askWithQuestions.utf8))).item
}

@Suite struct LocalQueueAnswersTests {
    @Test func answersAppendOneOwnerEventEachInOneWrite() async throws {
        let dir = QueueFixture.directory()
        defer { QueueFixture.remove(dir) }
        let queue = try await QueueFixture.openQueue(dir)
        let item = try await post(queue)
        let changes = await queue.subscribe()
        var reader = changes.makeAsyncIterator()

        let returned = try await queue.answer(item.id, answers: .array([
            Answers.entry(step: "2", text: "EU"), Answers.entry(step: "1", picked: ["Prod"]),
        ]))
        #expect(returned == item)
        let gotChange: Void? = await reader.next()
        #expect(gotChange != nil)
        let events = try #require(await queue.get(item.id)?.events)
        #expect(events.map(\.kind) == ["posted", "answer", "answer"])
        #expect(events.dropFirst().allSatisfy { $0.actor == "owner" })
        #expect(events.dropFirst().map(\.text) == [#"{"step":"2","text":"EU"}"#, #"{"step":"1","picked":["Prod"]}"#])
        #expect(await queue.get(item.id)?.item.status == "open")      // answering leaves the ask open

        // Persisted: a reopened queue still has them.
        await queue.close()
        let again = try await QueueFixture.openQueue(dir)
        #expect(await again.get(item.id)?.events.count == 3)
    }

    @Test func refusesUnknownClosedAndInvalid() async throws {
        let dir = QueueFixture.directory()
        defer { QueueFixture.remove(dir) }
        let queue = try await QueueFixture.openQueue(dir)
        let item = try await post(queue)
        let good = JSONValue.array([Answers.entry(step: "1", picked: ["Prod"])])

        await #expect(throws: LocalQueueError.notFound) {
            try await queue.answer("6f1c2b0e-8a1d-4c55-9a77-0d2f3c4b5a61", answers: good)
        }
        await #expect(throws: LocalQueueError.invalidAnswers(["answers[0].step: no question at this step"])) {
            try await queue.answer(item.id, answers: .array([Answers.entry(step: "3", text: "x")]))
        }
        _ = try await queue.resolve(item.id, verdict: "done", actor: "owner", note: nil)
        await #expect(throws: LocalQueueError.askClosed) { try await queue.answer(item.id, answers: good) }
        #expect(await queue.get(item.id)?.events.map(\.kind) == ["posted", "resolved"])

        _ = try await queue.reopen(item.id)
        _ = try await queue.answer(item.id, answers: good)
        #expect(await queue.get(item.id)?.events.last?.kind == "answer")
    }

    @Test func theSourceMapsErrorsForTheUI() async throws {
        let dir = QueueFixture.directory()
        defer { QueueFixture.remove(dir) }
        let queue = try await QueueFixture.openQueue(dir)
        let source = LocalQueueSource(queue: queue)
        let item = try await post(queue)

        let sent = try await source.answer(item.id, answers: [Answers.entry(step: "1", picked: ["Staging"])])
        #expect(sent.id == item.id)
        let detail = try await source.get(item.id)
        #expect(DetailModel.make(detail).nodes[0].answer?.picked == ["Staging"])
        #expect(DetailModel.make(detail).unanswered == ["2"])

        await #expect(throws: QueueError.rejected(status: 400, error: "invalid answers",
                                                  details: ["answers[0].picked: must list exactly 1 choice"])) {
            try await source.answer(item.id, answers: [Answers.entry(step: "1", picked: [])])
        }
        _ = try await source.resolve(item.id, verdict: .declined)
        await #expect(throws: QueueError.askClosed) {
            try await source.answer(item.id, answers: [Answers.entry(step: "2", text: "EU")])
        }
        #expect(QueueError.askClosed.errorDescription?.contains("Reopen") == true)
    }

    @Test func theLocalAPIServesAnswerEvents() async throws {
        let dir = QueueFixture.directory()
        defer { QueueFixture.remove(dir) }
        let queue = try await QueueFixture.openQueue(dir)
        let item = try await post(queue)
        _ = try await queue.answer(item.id, answers: .array([Answers.entry(step: "2", text: "EU")]))
        let token = String(repeating: "cd", count: 32)
        let api = LocalAPI(queue: queue, port: 47823, token: { token })
        func get(_ path: String) async throws -> JSONValue {
            let response = await api.handle(HTTPRequest(
                method: "GET", path: path, query: [:],
                headers: ["host": "127.0.0.1:47823", "authorization": "Bearer " + token], body: Data()))
            #expect(response.status == 200)
            return try JSONValue.parse(response.body)
        }
        let detail = try await get("/asks/\(item.id)")
        guard case .array(let events)? = detail["events"] else { Issue.record("no events"); return }
        #expect(events.last?["kind"] == .string("answer"))
        #expect(events.last?["actor"] == .string("owner"))
        #expect(events.last?["text"] == .string(#"{"step":"2","text":"EU"}"#))
        guard case .array(let all)? = try await get("/events")["events"] else { Issue.record("no events"); return }
        #expect(all.map { $0["kind"] } == [.string("posted"), .string("answer")])
        // No answers route: owner actions are app-only (R4).
        let post = await api.handle(HTTPRequest(
            method: "POST", path: "/asks/\(item.id)/answers", query: [:],
            headers: ["host": "127.0.0.1:47823", "authorization": "Bearer " + token], body: Data("{}".utf8)))
        #expect(post.status == 404)
    }
}
