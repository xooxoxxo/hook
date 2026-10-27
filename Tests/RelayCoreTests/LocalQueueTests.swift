import Foundation
import Testing
import os
@testable import RelayCore

/// A settable clock for `LocalQueue(now:)`. Shared with LocalQueueActionsTests.
final class QueueTestClock: Sendable {
    private let current: OSAllocatedUnfairLock<Date>

    init(_ start: Date = QueueFixture.start) {
        current = OSAllocatedUnfairLock(initialState: start)
    }

    var now: Date { current.withLock { $0 } }

    func advance(_ seconds: TimeInterval) {
        current.withLock { $0 += seconds }
    }
}

enum QueueFixture {
    /// 2026-10-03T04:00:00+00:00
    static let start = Date(timeIntervalSince1970: 1_791_000_000)
    static let hour: TimeInterval = 3600
    static let day: TimeInterval = 86_400

    static let wireKeys: Set<String> = [
        "id", "source", "title", "status", "priority", "pinned", "rolling", "payloadType",
        "payload", "links", "created", "updated", "anchor", "recurrence", "snoozeUntil",
        "projectId", "lane", "completedAt",
    ]

    static func directory() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "relay-queue-\(UUID().uuidString)")
    }

    static func remove(_ dir: URL) {
        try? FileManager.default.removeItem(at: dir)
    }

    /// A minimal valid instructable with this title.
    static func ask(_ title: String) throws -> JSONValue {
        try JSONValue.parse(Data(#"{"v":1,"title":"\#(title)","steps":[{"do":"Open the settings page"}]}"#.utf8))
    }

    static func openQueue(_ dir: URL, keepDays: Int = 14, clock: QueueTestClock = QueueTestClock()) async throws -> LocalQueue {
        let queue = LocalQueue(directory: dir, keepDays: keepDays, now: { clock.now })
        _ = try await queue.open()
        return queue
    }

    static func mode(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try #require(attributes[.posixPermissions] as? NSNumber).intValue
    }

    /// Opens `dir` again after a `close()`: `open` itself rides out a lock a spawned child
    /// still shares for a moment (`LocalQueue.lock`).
    static func reopenQueue(_ dir: URL, keepDays: Int = 14,
                            clock: QueueTestClock = QueueTestClock()) async throws -> (LocalQueue, QueueLoadOutcome) {
        let queue = LocalQueue(directory: dir, keepDays: keepDays, now: { clock.now })
        return (queue, try await queue.open())
    }

    /// Polls for up to 2 s.
    static func waitUntil(_ condition: @Sendable () async -> Bool) async throws {
        for _ in 0..<200 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("condition not met within 2 s")
    }
}

@Suite struct LocalQueueTests {
    @Test func postCreatesEveryWireKey() async throws {
        let dir = QueueFixture.directory()
        defer { QueueFixture.remove(dir) }
        let clock = QueueTestClock()
        let queue = LocalQueue(directory: dir, keepDays: 14, now: { clock.now })
        #expect(try await queue.open() == .fresh)

        let (item, deduped) = try await queue.post(project: .string("Acme"), instructable: QueueFixture.ask("Rotate the key"))
        #expect(!deduped)

        let object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(item)) as? [String: Any])
        #expect(Set(object.keys) == QueueFixture.wireKeys)
        #expect(QueueLogic.normalizedID(item.id) == item.id)
        #expect(object["source"] as? String == "relay-local")
        #expect(object["title"] as? String == "Rotate the key")
        #expect(object["status"] as? String == "open")
        #expect(object["priority"] as? Int == 1)
        #expect(object["pinned"] as? Bool == false)
        #expect(object["rolling"] as? Bool == false)
        #expect(object["payloadType"] as? String == "relay.ask")
        #expect((object["links"] as? [Any])?.isEmpty == true)
        #expect(object["created"] as? String == "2026-10-03T04:00:00+00:00")
        #expect(object["updated"] as? String == "2026-10-03T04:00:00+00:00")
        #expect(object["anchor"] is NSNull)
        #expect(object["recurrence"] is NSNull)
        #expect(object["snoozeUntil"] is NSNull)
        #expect(object["projectId"] as? String == "Acme")
        #expect(object["lane"] as? String == "local")
        #expect(object["completedAt"] is NSNull)

        let payload = try #require(object["payload"] as? [String: Any])
        #expect(Set(payload.keys) == ["why", "key", "instructable"])
        #expect(payload["why"] is NSNull)
        // sha1("Acme\nRotate the key")[:16], computed with Python's hashlib.
        #expect(payload["key"] as? String == "cb5a1ee5ba494638")
        #expect(item.payload.instructable["urgency"] == .string("today"))

        let wire = item.wireItem
        #expect(wire.id == item.id)
        #expect(wire.projectId == "Acme")
        #expect(wire.instructable?.title == "Rotate the key")
        #expect(wire.instructable?.steps.first?.action == "Open the settings page")

        let detail = try #require(await queue.get(item.id))
        #expect(detail.item == item)
        #expect(detail.events.map(\.kind) == ["posted"])
        #expect(detail.events.first?.actor == "session")
        #expect(detail.events.first?.text == nil)
        #expect(detail.events.first?.seq == 1)
        #expect(detail.events.first?.event.itemId == item.id)

        // The event wire shape: "text" is
        // always present, as null when there is no text.
        let posted = try #require(detail.events.first)
        let eventObject = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(posted)) as? [String: Any])
        #expect(Set(eventObject.keys) == ["seq", "itemId", "kind", "actor", "text", "at"])
        #expect(eventObject["text"] is NSNull)
    }

    @Test func postChecksInOrder() async throws {
        let dir = QueueFixture.directory()
        defer { QueueFixture.remove(dir) }
        let queue = try await QueueFixture.openQueue(dir)
        let valid = try QueueFixture.ask("Rotate the key")

        await #expect(throws: LocalQueueError.missingFields) {
            try await queue.post(project: .string("Acme"), instructable: nil)
        }
        await #expect(throws: LocalQueueError.missingFields) {
            try await queue.post(project: .string("Acme"), instructable: .null)
        }
        do {
            _ = try await queue.post(project: nil, instructable: .object(["v": .int(1)]))
            Issue.record("an invalid instructable was accepted")
        } catch LocalQueueError.invalidInstructable(let errors) {
            #expect(!errors.isEmpty)
        }
        await #expect(throws: LocalQueueError.invalidProject(["project: required"])) {
            try await queue.post(project: nil, instructable: valid)
        }
        #expect(await queue.list(status: "all", days: nil).isEmpty)
    }

    @Test func dedupesOnProjectAndTitle() async throws {
        let dir = QueueFixture.directory()
        defer { QueueFixture.remove(dir) }
        let queue = try await QueueFixture.openQueue(dir)
        let instructable = try QueueFixture.ask("Rotate the key")

        let first = try await queue.post(project: .string("Acme"), instructable: instructable)
        let again = try await queue.post(project: .string("Acme"), instructable: instructable)
        #expect(!first.deduped)
        #expect(again.deduped)
        #expect(again.item == first.item)

        let other = try await queue.post(project: .string("Acme-Lab"), instructable: instructable)
        #expect(!other.deduped)
        #expect(other.item.id != first.item.id)

        #expect(await queue.list(status: "open", days: nil).count == 2)
        // A deduped post adds no event.
        #expect(await queue.events(after: 0, limit: 100).events.map(\.kind) == ["posted", "posted"])
    }

    @Test func fullQueueRefusesNewAsksButStillDedupes() async throws {
        let dir = QueueFixture.directory()
        defer { QueueFixture.remove(dir) }
        let queue = try await QueueFixture.openQueue(dir)
        for n in 1...LocalQueue.maxOpen {
            _ = try await queue.post(project: .string("Acme"), instructable: QueueFixture.ask("Ask \(n)"))
        }
        #expect(await queue.list(status: "open", days: nil).count == 200)

        let hit = try await queue.post(project: .string("Acme"), instructable: QueueFixture.ask("Ask 7"))
        #expect(hit.deduped)
        #expect(hit.item.title == "Ask 7")

        let extra = try QueueFixture.ask("Ask 201")
        await #expect(throws: LocalQueueError.queueFull) {
            try await queue.post(project: .string("Acme"), instructable: extra)
        }
        #expect(await queue.list(status: "open", days: nil).count == 200)
    }

    @Test func listFiltersAndSortsAndEventsPage() async throws {
        let dir = QueueFixture.directory()
        defer { QueueFixture.remove(dir) }
        let clock = QueueTestClock()
        let queue = try await QueueFixture.openQueue(dir, clock: clock)
        let a = try await queue.post(project: .string("Acme"), instructable: QueueFixture.ask("First")).item
        clock.advance(QueueFixture.hour)
        let b = try await queue.post(project: .string("Acme"), instructable: QueueFixture.ask("Second")).item

        #expect(await queue.list(status: "open", days: nil).map(\.id) == [b.id, a.id])
        #expect(await queue.list(status: "all", days: 14).map(\.id) == [b.id, a.id])
        #expect(await queue.list(status: "done", days: nil).isEmpty)
        clock.advance(QueueFixture.day + QueueFixture.hour / 2)
        // a is now 1 d 1.5 h old, b 1 d 0.5 h: only "days: 0" excludes both.
        #expect(await queue.list(status: "open", days: 2).count == 2)
        #expect(await queue.list(status: "open", days: 0).isEmpty)

        let page = await queue.events(after: 1, limit: 10)
        #expect(page.events.map(\.seq) == [2])
        #expect(page.events.first?.itemId == b.id)
        #expect(page.next == 2)
        let empty = await queue.events(after: 2, limit: 10)
        #expect(empty.events.isEmpty)
        #expect(empty.next == 2)
        #expect(await queue.events(after: 0, limit: 1).events.map(\.seq) == [1])
        #expect(await queue.get("00000000-0000-4000-8000-000000000000") == nil)
    }

    /// A failed write leaves memory unchanged and the caller gets
    /// `storeFailed` (HTTP 500 "store failed"). A non-empty directory at
    /// queue.json makes the rename fail.
    @Test func failedWriteLeavesMemoryUnchanged() async throws {
        let dir = QueueFixture.directory()
        defer { QueueFixture.remove(dir) }
        let queue = try await QueueFixture.openQueue(dir)
        let first = try await queue.post(project: .string("Acme"), instructable: QueueFixture.ask("First")).item
        let listBefore = await queue.list(status: "all", days: nil)
        let eventsBefore = await queue.events(after: 0, limit: 100)

        let file = dir.appending(path: "queue.json")
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        try Data("x".utf8).write(to: file.appending(path: "keep"))

        await #expect {
            _ = try await queue.post(project: .string("Acme"), instructable: QueueFixture.ask("Second"))
        } throws: { error in
            if case LocalQueueError.storeFailed = error { return true }
            return false
        }
        #expect(await queue.list(status: "all", days: nil) == listBefore)
        let eventsAfter = await queue.events(after: 0, limit: 100)
        #expect(eventsAfter.events == eventsBefore.events)
        #expect(eventsAfter.next == eventsBefore.next)

        let token = String(repeating: "ab", count: 32)
        let api = LocalAPI(queue: queue, port: 47823, token: { token })
        let body = #"{"project":"Acme","context":"work","instructable":{"v":1,"title":"Third","steps":[{"do":"Open the vault"}]}}"#
        let response = await api.handle(HTTPRequest(
            method: "POST", path: "/asks", query: [:],
            headers: ["host": "127.0.0.1:47823", "authorization": "Bearer " + token],
            body: Data(body.utf8)))
        #expect(response.status == 500)
        #expect((try? JSONValue.parse(response.body))?["error"]?.stringValue == "store failed")
        #expect(await queue.list(status: "all", days: nil).map(\.id) == [first.id])
    }

    @Test func reloadKeepsEverythingInPrivateFiles() async throws {
        let dir = QueueFixture.directory()
        defer { QueueFixture.remove(dir) }
        let first = try await QueueFixture.openQueue(dir)
        _ = try await first.post(project: .string("Acme"), instructable: QueueFixture.ask("Rotate the key"))
        _ = try await first.post(project: .string("Acme"), instructable: QueueFixture.ask("Approve the deploy"))
        let saved = await first.state
        await first.close()

        let second = LocalQueue(directory: dir, keepDays: 14)
        #expect(try await second.open() == .loaded)
        #expect(await second.state == saved)
        #expect(await second.epoch == saved.epoch)
        #expect(try QueueFixture.mode(dir.appending(path: "queue.json")) == 0o600)
        #expect(try QueueFixture.mode(dir) == 0o700)
    }

    @Test func corruptFileIsMovedAsideAndANewEpochStarts() async throws {
        let dir = QueueFixture.directory()
        defer { QueueFixture.remove(dir) }
        let first = try await QueueFixture.openQueue(dir)
        let oldEpoch = await first.epoch
        await first.close()
        try Data("{not json".utf8).write(to: dir.appending(path: "queue.json"))

        let second = LocalQueue(directory: dir, keepDays: 14)
        let outcome = try await second.open()
        guard case .recovered(let moved) = outcome else {
            Issue.record("expected .recovered, got \(outcome)")
            return
        }
        #expect(URL(fileURLWithPath: moved).lastPathComponent.hasPrefix("queue.json.corrupt-"))
        #expect(try String(contentsOfFile: moved, encoding: .utf8) == "{not json")
        let newEpoch = await second.epoch
        #expect(newEpoch != oldEpoch)
        #expect(newEpoch.count == 16)
        #expect(await second.list(status: "all", days: nil).isEmpty)
        let data = try Data(contentsOf: dir.appending(path: "queue.json"))
        #expect(try JSONDecoder().decode(QueueState.self, from: data).epoch == newEpoch)
    }

    @Test func secondQueueOnTheSameDirectoryIsLocked() async throws {
        let dir = QueueFixture.directory()
        defer { QueueFixture.remove(dir) }
        let first = try await QueueFixture.openQueue(dir)
        let second = LocalQueue(directory: dir, keepDays: 14, lockWait: 0.05)
        await #expect(throws: LocalQueueError.locked) {
            try await second.open()
        }
        await first.close()
        #expect(try await second.open() == .loaded)
    }

    /// The flake's cause: a child spawned by any thread shares the lock's open file until
    /// its exec, so right after `close()` the lock can read as taken. `open` waits it out.
    @Test func aLockAChildBrieflySharesIsWaitedOut() async throws {
        let dir = QueueFixture.directory()
        defer { QueueFixture.remove(dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appending(path: "probe.lock").path
        let spawning = Task.detached {
            while !Task.isCancelled {
                let child = Process()
                child.executableURL = URL(fileURLWithPath: "/usr/bin/true")
                try? child.run()
                child.waitUntilExit()
            }
        }
        defer { spawning.cancel() }
        var failures = 0
        let until = Date().addingTimeInterval(1)
        while Date() < until {
            let fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
            if LocalQueue.lock(fd, waitingUpTo: LocalQueue.defaultLockWait) != 0 { failures += 1 }
            close(fd)
        }
        #expect(failures == 0)

        // Reopening the queue itself while children spawn: never locked.
        for _ in 0..<50 {
            let (queue, _) = try await QueueFixture.reopenQueue(dir)
            await queue.close()
        }
    }

    /// A lock released during the wait is taken; one held throughout is `.locked`.
    @Test func theLockWaitIsBounded() async throws {
        let dir = QueueFixture.directory()
        defer { QueueFixture.remove(dir) }
        let holder = try await QueueFixture.openQueue(dir)
        let started = Date()
        await #expect(throws: LocalQueueError.locked) {
            try await LocalQueue(directory: dir, keepDays: 14, lockWait: 0.2).open()
        }
        #expect(Date().timeIntervalSince(started) >= 0.2)
        Task.detached {
            try? await Task.sleep(for: .milliseconds(100))
            await holder.close()
        }
        #expect(try await LocalQueue(directory: dir, keepDays: 14, lockWait: 2).open() == .loaded)
    }

    @Test func retentionDropsOldFinishedAsksAndKeepsOpenOnes() async throws {
        let dir = QueueFixture.directory()
        defer { QueueFixture.remove(dir) }
        let clock = QueueTestClock()
        let queue = try await QueueFixture.openQueue(dir, keepDays: 30, clock: clock)
        let old = try await queue.post(project: .string("Acme"), instructable: QueueFixture.ask("Old done")).item
        let open = try await queue.post(project: .string("Acme"), instructable: QueueFixture.ask("Still open")).item
        let recent = try await queue.post(project: .string("Acme"), instructable: QueueFixture.ask("Recent done")).item

        // Finish two asks directly through the internal commit.
        clock.advance(15 * QueueFixture.day)
        var s = await queue.state
        for (id, finished) in [(old.id, QueueFixture.start), (recent.id, clock.now - 13 * QueueFixture.day)] {
            let i = try #require(s.items.firstIndex { $0.id == id })
            s.items[i].status = "done"
            s.items[i].completedAt = Timestamp.string(finished)
        }
        try await queue.commit(s)
        #expect(await queue.list(status: "all", days: nil).count == 3)

        await queue.setKeepDays(14)
        #expect(Set(await queue.list(status: "all", days: nil).map(\.id)) == [open.id, recent.id])
        #expect(await queue.get(old.id) == nil)
        #expect(await queue.events(after: 0, limit: 100).events.allSatisfy { $0.itemId != old.id })

        // The pruned state is on disk too.
        await queue.close()
        let (reopened, outcome) = try await QueueFixture.reopenQueue(dir, clock: clock)
        #expect(outcome == .loaded)
        #expect(await reopened.get(old.id) == nil)
        #expect(await reopened.get(open.id) != nil)
    }

    /// A Mac whose time zone isn't UTC.
    @Test func timestampsAndDedupeIgnoreTheLocalTimeZone() async throws {
        // Set for the rest of the test process on purpose: correct code never reads
        // it, and restoring it could race another test that sets the same zone.
        NSTimeZone.default = try #require(TimeZone(identifier: "Europe/Istanbul"))

        #expect(Timestamp.string(QueueFixture.start) == "2026-10-03T04:00:00+00:00")
        #expect(Timestamp.date("2026-10-03T07:00:00+03:00") == QueueFixture.start)
        #expect(Timestamp.date("2026-10-03T04:00:00Z") == QueueFixture.start)
        #expect(Timestamp.date("2026-10-03T04:00:00+00:00") == QueueFixture.start)
        #expect(Timestamp.date("yesterday") == nil)

        let dir = QueueFixture.directory()
        defer { QueueFixture.remove(dir) }
        let clock = QueueTestClock()
        let queue = try await QueueFixture.openQueue(dir, clock: clock)
        let instructable = try QueueFixture.ask("Rotate the key")

        let first = try await queue.post(project: .string("Acme"), instructable: instructable)
        #expect(first.item.created.hasSuffix("+00:00"))
        #expect(first.item.created == "2026-10-03T04:00:00+00:00")
        let event = try #require(await queue.events(after: 0, limit: 1).events.first)
        #expect(event.at.hasSuffix("+00:00"))

        clock.advance(23 * QueueFixture.hour)
        let within = try await queue.post(project: .string("Acme"), instructable: instructable)
        #expect(within.deduped)
        #expect(within.item.id == first.item.id)

        clock.advance(2 * QueueFixture.hour)
        let after = try await queue.post(project: .string("Acme"), instructable: instructable)
        #expect(!after.deduped)
        #expect(after.item.id != first.item.id)
        #expect(after.item.created == "2026-10-04T05:00:00+00:00")
    }

    /// Two sessions posting the same ask at the same moment.
    @Test func concurrentIdenticalPostsCreateOneItem() async throws {
        let dir = QueueFixture.directory()
        defer { QueueFixture.remove(dir) }
        let queue = try await QueueFixture.openQueue(dir)
        let instructable = try QueueFixture.ask("Approve the deploy")

        let flags = try await withThrowingTaskGroup(of: Bool.self, returning: [Bool].self) { group in
            for _ in 0..<10 {
                group.addTask {
                    try await queue.post(project: .string("Acme"), instructable: instructable).deduped
                }
            }
            var all: [Bool] = []
            for try await flag in group { all.append(flag) }
            return all
        }
        #expect(flags.count == 10)
        #expect(flags.filter { $0 }.count == 9)
        #expect(await queue.list(status: "all", days: nil).count == 1)
        #expect(await queue.events(after: 0, limit: 100).events.count == 1)
    }
}
