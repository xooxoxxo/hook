import Foundation
import Testing
@testable import RelayCore

private let rawAsk = #"{"v":1,"title":"Rotate the key","steps":[{"do":"Open the vault"}]}"#

private func makeSource() async throws -> LocalQueueSource {
    let dir = FileManager.default.temporaryDirectory.appending(path: "relay-src-\(UUID().uuidString)")
    let queue = LocalQueue(directory: dir, keepDays: 14)
    _ = try await queue.open()
    return LocalQueueSource(queue: queue)
}

private func rejection<T>(_ body: () async throws -> T) async -> QueueError? {
    do {
        _ = try await body()
        return nil
    } catch {
        return error as? QueueError
    }
}

@Suite struct LocalQueueSourceTests {
    @Test func postThenListAndGet() async throws {
        let source = try await makeSource()
        let posted = try await source.post(project: "Acme", instructable: Data(rawAsk.utf8))
        #expect(!posted.deduped)
        #expect(posted.openURL == nil)
        #expect(posted.item.title == "Rotate the key")
        #expect(posted.item.projectId == "Acme")
        #expect(posted.item.status == "open")
        #expect(posted.item.instructable?.urgency == "today")   // cleaned: urgency defaulted

        let listed = try await source.list()
        #expect(listed.map(\.id) == [posted.item.id])
        let detail = try await source.get(posted.item.id)
        #expect(detail.item == posted.item)
        #expect(detail.events.map(\.kind) == ["posted"])
        #expect(detail.events.first?.actor == "session")

        let again = try await source.post(project: "Acme", instructable: Data(rawAsk.utf8))
        #expect(again.deduped)
        #expect(again.item.id == posted.item.id)
    }

    @Test func rejectedPostsMapToSpecErrors() async throws {
        let source = try await makeSource()

        let bad = #"{"v":1,"title":"Rotate the key"}"#
        let expected: [String]
        switch Validator.validate(try JSONValue.parse(Data(bad.utf8))) {
        case .success: expected = []
        case .failure(let failure): expected = failure.errors
        }
        #expect(!expected.isEmpty)
        let invalid = await rejection { try await source.post(project: "Acme", instructable: Data(bad.utf8)) }
        guard case .rejected(let status, let error, let details)? = invalid else {
            Issue.record("expected .rejected, got \(String(describing: invalid))")
            return
        }
        #expect(status == 400)
        #expect(error == "invalid instructable")
        #expect(details.sorted() == expected.sorted())

        let project = await rejection { try await source.post(project: "", instructable: Data(rawAsk.utf8)) }
        #expect(project == .rejected(status: 400, error: "invalid project", details: Validator.validateProject(.string(""))))

        let json = await rejection { try await source.post(project: "Acme", instructable: Data("{".utf8)) }
        #expect(json == .rejected(status: 400, error: "invalid json", details: []))

        let left = try await source.list()
        #expect(left.isEmpty)
    }

    @Test func resolveAndReplyActAsTheOwner() async throws {
        let source = try await makeSource()
        let id = try await source.post(project: "Acme", instructable: Data(rawAsk.utf8)).item.id

        let replied = try await source.reply(id, text: "  choice: Yes \n")
        #expect(replied.status == "open")
        var events = try await source.get(id).events
        #expect(events.last?.kind == "reply")
        #expect(events.last?.actor == "owner")
        #expect(events.last?.text == "choice: Yes")

        let done = try await source.resolve(id, verdict: .done)
        #expect(done.status == "done")
        events = try await source.get(id).events
        #expect(events.last?.kind == "resolved")
        #expect(events.last?.actor == "owner")
        let open = try await source.list()
        #expect(open.isEmpty)
    }

    @Test func unknownIDsAreNotFound() async throws {
        let source = try await makeSource()
        let missing = "6f1c2b0e-8a1d-4c55-9a77-0d2f3c4b5a61"
        await #expect(throws: QueueError.notFound) { try await source.get(missing) }
        await #expect(throws: QueueError.notFound) { try await source.resolve(missing, verdict: .declined, note: nil) }
        await #expect(throws: QueueError.notFound) { try await source.reply(missing, text: "hi") }
    }

    @Test(.timeLimit(.minutes(1))) func changesYieldAfterAPost() async throws {
        let source = try await makeSource()
        let stream = try #require(await source.changes())
        _ = try await source.post(project: "Acme", instructable: Data(rawAsk.utf8))
        var received = false
        for await _ in stream {
            received = true
            break
        }
        #expect(received)
    }

    @Test func errorMappingTable() {
        #expect(LocalQueueError.queueFull.queueError == .rejected(status: 429, error: "queue full", details: []))
        #expect(LocalQueueError.missingFields.queueError == .rejected(status: 400, error: "missing fields", details: []))
        #expect(LocalQueueError.invalidNote(["note: longer than 300 characters"]).queueError
            == .rejected(status: 400, error: "invalid note", details: ["note: longer than 300 characters"]))
        #expect(LocalQueueError.notFound.queueError == .notFound)
        #expect(LocalQueueError.storeFailed("disk full").queueError == .storeFailed("disk full"))
        #expect(LocalQueueError.storeFailed("disk full").wire.status == 500)
        #expect(LocalQueueError.storeFailed("disk full").wire.error == "store failed")
        #expect(LocalQueueError.textTooLong.wire.error == "text too long")
    }
}
