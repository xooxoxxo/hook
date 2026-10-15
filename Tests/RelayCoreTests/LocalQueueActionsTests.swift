import Foundation
import Testing
@testable import RelayCore

@Suite struct LocalQueueActionsTests {
    @Test func resolveDoneAndDeclined() async throws {
        let dir = QueueFixture.directory()
        defer { QueueFixture.remove(dir) }
        let clock = QueueTestClock()
        let queue = try await QueueFixture.openQueue(dir, clock: clock)
        let a = try await queue.post(project: .string("Acme"), instructable: QueueFixture.ask("Rotate the key")).item
        let b = try await queue.post(project: .string("Acme"), instructable: QueueFixture.ask("Approve the deploy")).item
        clock.advance(QueueFixture.hour)

        let done = try await queue.resolve(a.id, verdict: "done", actor: "session", note: .string("Rotated it"))
        #expect(done.status == "done")
        #expect(done.completedAt == "2026-10-03T05:00:00+00:00")
        #expect(done.updated == "2026-10-03T05:00:00+00:00")
        #expect(done.created == a.created)
        let doneEvent = try #require(await queue.get(a.id)?.events.last)
        #expect(doneEvent.kind == "resolved")
        #expect(doneEvent.actor == "session")
        #expect(doneEvent.text == "Rotated it")

        let skipped = try await queue.resolve(b.id, verdict: "declined", actor: "owner", note: nil)
        #expect(skipped.status == "dismissed")
        #expect(skipped.completedAt != nil)
        let skipEvent = try #require(await queue.get(b.id)?.events.last)
        #expect(skipEvent.kind == "declined")
        #expect(skipEvent.actor == "owner")
        #expect(skipEvent.text == nil)

        #expect(await queue.list(status: "open", days: nil).isEmpty)
        #expect(await queue.list(status: "done", days: nil).map(\.id) == [a.id])
        #expect(await queue.list(status: "dismissed", days: nil).map(\.id) == [b.id])
    }

    @Test func resolvingAFinishedAskChangesNothing() async throws {
        let dir = QueueFixture.directory()
        defer { QueueFixture.remove(dir) }
        let queue = try await QueueFixture.openQueue(dir)
        let a = try await queue.post(project: .string("Acme"), instructable: QueueFixture.ask("Rotate the key")).item
        let done = try await queue.resolve(a.id, verdict: "done", actor: "session", note: nil)
        let before = await queue.state

        let again = try await queue.resolve(a.id, verdict: "declined", actor: "session", note: .string("Changed my mind"))
        #expect(again == done)
        #expect(again.status == "done")
        #expect(await queue.state == before)
        #expect(await queue.get(a.id)?.events.map(\.kind) == ["posted", "resolved"])
    }

    @Test func resolveChecksTheNoteAndTheID() async throws {
        let dir = QueueFixture.directory()
        defer { QueueFixture.remove(dir) }
        let queue = try await QueueFixture.openQueue(dir)
        let a = try await queue.post(project: .string("Acme"), instructable: QueueFixture.ask("Rotate the key")).item
        let b = try await queue.post(project: .string("Acme"), instructable: QueueFixture.ask("Approve the deploy")).item

        let long = JSONValue.string(String(repeating: "a", count: 301))
        await #expect(throws: LocalQueueError.invalidNote(["note: longer than 300 characters"])) {
            try await queue.resolve(a.id, verdict: "done", actor: "session", note: long)
        }
        #expect(await queue.get(a.id)?.item.status == "open")

        await #expect(throws: LocalQueueError.notFound) {
            try await queue.resolve("00000000-0000-4000-8000-000000000000", verdict: "done", actor: "session", note: nil)
        }

        // Multi-line notes are allowed, like `why`.
        _ = try await queue.resolve(a.id, verdict: "done", actor: "session", note: .string("line one\nline two"))
        #expect(await queue.get(a.id)?.events.last?.text == "line one\nline two")

        // An empty note is stored as no note.
        _ = try await queue.resolve(b.id, verdict: "done", actor: "session", note: .string(""))
        #expect(await queue.get(b.id)?.events.last?.text == nil)
    }

    @Test func replyIsTrimmedAndBounded() async throws {
        let dir = QueueFixture.directory()
        defer { QueueFixture.remove(dir) }
        let queue = try await QueueFixture.openQueue(dir)
        let a = try await queue.post(project: .string("Acme"), instructable: QueueFixture.ask("Rotate the key")).item

        let replied = try await queue.reply(a.id, text: "  Use the staging key \n")
        #expect(replied == a)
        let event = try #require(await queue.get(a.id)?.events.last)
        #expect(event.kind == "reply")
        #expect(event.actor == "owner")
        #expect(event.text == "Use the staging key")

        await #expect(throws: LocalQueueError.missingText) {
            try await queue.reply(a.id, text: " \n\t ")
        }
        await #expect(throws: LocalQueueError.textTooLong) {
            try await queue.reply(a.id, text: String(repeating: "a", count: 4001))
        }
        _ = try await queue.reply(a.id, text: String(repeating: "a", count: 4000))
        await #expect(throws: LocalQueueError.notFound) {
            try await queue.reply("00000000-0000-4000-8000-000000000000", text: "hello")
        }

        // Works on a finished ask too.
        _ = try await queue.resolve(a.id, verdict: "done", actor: "owner", note: nil)
        _ = try await queue.reply(a.id, text: "Thanks")
        #expect(await queue.get(a.id)?.events.last?.text == "Thanks")
    }

    @Test func everySubscriberSeesChangesAndCancelledOnesAreDropped() async throws {
        let dir = QueueFixture.directory()
        defer { QueueFixture.remove(dir) }
        let queue = try await QueueFixture.openQueue(dir)

        let first = await queue.subscribe()
        let second = await queue.subscribe()
        _ = try await queue.post(project: .string("Acme"), instructable: QueueFixture.ask("Rotate the key"))
        var firstReader = first.makeAsyncIterator()
        var secondReader = second.makeAsyncIterator()
        let gotFirst: Void? = await firstReader.next()
        let gotSecond: Void? = await secondReader.next()
        #expect(gotFirst != nil)
        #expect(gotSecond != nil)

        let cancelled = await queue.subscribe()
        #expect(await queue.subscribers.count == 3)
        let reader = Task { for await _ in cancelled {} }
        reader.cancel()
        await reader.value
        try await QueueFixture.waitUntil { await queue.subscribers.count == 2 }

        let fresh = await queue.subscribe()
        _ = try await queue.post(project: .string("Acme"), instructable: QueueFixture.ask("Approve the deploy"))
        var freshReader = fresh.makeAsyncIterator()
        let gotFresh: Void? = await freshReader.next()
        let gotFirstAgain: Void? = await firstReader.next()
        #expect(gotFresh != nil)
        #expect(gotFirstAgain != nil)
    }
}
