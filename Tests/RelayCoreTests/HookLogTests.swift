import Foundation
import Testing
@testable import RelayCore

private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory.appending(path: "hook-log-tests-\(UUID().uuidString)")
}

private let fixedNow: @Sendable () -> Date = { Date(timeIntervalSince1970: 1_793_700_000) }   // 2026-11-03T…Z

@Suite struct HookLogEventTests {
    private func line(_ event: HookLog.Event) -> String { event.line(home: "/Users/me", user: "me") }

    @Test func eachEventFormatsToOneStableLine() {
        #expect(line(.launch(hook: "0.12.0", macOS: "15.1.1", cpu: "arm64")) == "launch hook=0.12.0 macos=15.1.1 cpu=arm64")
        #expect(line(.quit(clean: true)) == "quit clean=true")
        #expect(line(.quit(clean: false)) == "quit clean=false")
        #expect(line(.screen(.settingsGeneral)) == "screen settingsGeneral")
        #expect(line(.action(.done)) == "action done")
        #expect(line(.source(.mailbox, pond: "1.2.0")) == "source mailbox pond=1.2.0")
        #expect(line(.source(.local, pond: nil)) == "source local")
        #expect(line(.error(type: "URLError", status: 503, route: "asks/42/reply", message: "timed out"))
            == #"error type=URLError status=503 route=asks/{id}/reply message="timed out""#)
        #expect(line(.error(type: "Store", status: nil, route: nil, message: "couldn't save"))
            == #"error type=Store message="couldn't save""#)
        #expect(line(.crashFound(signature: "a3f9c2e17b04", report: true)) == "crash signature=a3f9c2e17b04 report=true")
        #expect(line(.presence(.away, reason: "screen locked")) == #"presence away reason="screen locked""#)
    }

    @Test func anErrorMessageIsRedactedAndKeptOnOneLine() {
        let text = line(.error(type: "Mailbox", status: nil, route: nil,
                               message: "can't reach https://pond.example.com/asks\nfrom /Users/me/x \"quoted\""))
        #expect(text == #"error type=Mailbox message="can't reach <host> from ~/x 'quoted'""#)
    }

    @Test func freeFormFieldsCantBreakTheLine() {
        // A version or type with spaces, quotes or a newline is cut back to its safe characters.
        #expect(line(.launch(hook: "0.12.0 evil\nline", macOS: "15", cpu: "arm64")) == "launch hook=0.12.0evilline macos=15 cpu=arm64")
        #expect(line(.source(.mailbox, pond: "https://pond.example.com")) == "source mailbox pond=?")
        #expect(line(.crashFound(signature: "not hex!", report: false)) == "crash signature=? report=false")
    }

    @Test func aLongMessageIsCapped() {
        let text = line(.error(type: "X", status: nil, route: nil, message: String(repeating: "word ", count: 200)))
        #expect(text.count < 400)
    }
}

@Suite struct RollingLogTests {
    @Test func appendWritesOneTimestampedLine() throws {
        let dir = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = RollingLog(directory: dir, now: fixedNow)
        try log.append("launch hook=0.12.0")
        let text = try String(contentsOf: dir.appending(path: "hook.log"), encoding: .utf8)
        #expect(text == "2026-11-03T10:00:00Z launch hook=0.12.0\n")
    }

    @Test func theLogIsPrivate() throws {
        let dir = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try RollingLog(directory: dir, now: fixedNow).append("x")
        let attributes = try FileManager.default.attributesOfItem(atPath: dir.appending(path: "hook.log").path)
        #expect(((attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o777 == 0o600)
    }

    @Test func rotationKeepsAtMostTwoFiles() throws {
        let dir = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let limit = 512 * 1024
        let log = RollingLog(directory: dir, limit: limit, now: fixedNow)
        let line = String(repeating: "a", count: 999)
        for _ in 0..<1600 { try log.append(line) }   // about 1.6 MB written in all
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        #expect(names == ["hook.1.log", "hook.log"])
        let sizes = try names.map { try FileManager.default.attributesOfItem(atPath: dir.appending(path: $0).path)[.size] as? Int ?? 0 }
        #expect(sizes.allSatisfy { $0 <= limit })
        #expect(sizes.reduce(0, +) <= 1024 * 1024)
        #expect(log.size <= 1024 * 1024)
    }

    @Test func tailSpansBothFiles() throws {
        let dir = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = RollingLog(directory: dir, limit: 1000, now: fixedNow)
        for i in 0..<60 { try log.append(String(format: "line %02d", i)) }
        let rotated = try String(contentsOf: dir.appending(path: "hook.1.log"), encoding: .utf8)
        #expect(!rotated.isEmpty)
        let tail = log.tail(40)
        #expect(tail.count == 40)
        #expect(tail.last?.hasSuffix("line 59") == true)
        #expect(tail.first?.hasSuffix("line 20") == true)
    }

    @Test func tailOfAnEmptyLogIsEmpty() {
        let dir = temporaryDirectory()
        #expect(RollingLog(directory: dir, now: fixedNow).tail(40).isEmpty)
        #expect(RollingLog(directory: dir, now: fixedNow).size == 0)
    }

    @Test func aLineWrittenBeforeAKillIsReadable() throws {
        let dir = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try RollingLog(directory: dir, now: fixedNow).append("crash signature=a3f9c2e17b04 report=true")
        // A fresh handle, no flush or close of anything that wrote: what a relaunch after a kill sees.
        let handle = try FileHandle(forReadingFrom: dir.appending(path: "hook.log"))
        defer { try? handle.close() }
        let text = String(decoding: try handle.readToEnd() ?? Data(), as: UTF8.self)
        #expect(text.hasSuffix("crash signature=a3f9c2e17b04 report=true\n"))
    }

    @Test func aLineWithANewlineStaysOneLine() throws {
        let dir = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = RollingLog(directory: dir, now: fixedNow)
        try log.append("one\ntwo")
        #expect(log.tail(5) == ["2026-11-03T10:00:00Z one two"])
    }
}

@Suite struct HookLogTests {
    @Test func theStandardDirectoryIsLogsHook() {
        #expect(HookLog.directory(home: "/Users/me").path == "/Users/me/Library/Logs/Hook")
    }

    @Test func recordWritesToTheConfiguredLogOnly() throws {
        let dir = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = RollingLog(directory: dir, now: fixedNow)
        HookLog.withLog(log) {
            HookLog.record(.quit(clean: true))
            #expect(HookLog.tail(50).contains("2026-11-03T10:00:00Z quit clean=true"))
            #expect(HookLog.size > 0)
        }
    }
}

@Suite struct UpdateLogMoveTests {
    @Test func theOldUpdateLogMovesOnce() throws {
        let home = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let old = home.appending(path: "Library/Logs/Relay/update.log")
        try FileManager.default.createDirectory(at: old.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("old run\n".utf8).write(to: old)

        HookLog.moveOldUpdateLog(home: home.path)

        let new = home.appending(path: "Library/Logs/Hook/update.log")
        #expect(try String(contentsOf: new, encoding: .utf8) == "old run\n")
        #expect(!FileManager.default.fileExists(atPath: old.path))
        // The emptied Logs/Relay folder goes too.
        #expect(!FileManager.default.fileExists(atPath: old.deletingLastPathComponent().path))
        #expect(HookLog.updateLogPath(home: home.path) == new.path)
    }

    @Test func aNewerLogIsNeverOverwritten() throws {
        let home = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let old = home.appending(path: "Library/Logs/Relay/update.log")
        let new = home.appending(path: "Library/Logs/Hook/update.log")
        for url in [old, new] {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        try Data("old\n".utf8).write(to: old)
        try Data("new\n".utf8).write(to: new)

        HookLog.moveOldUpdateLog(home: home.path)

        #expect(try String(contentsOf: new, encoding: .utf8) == "new\n")
        #expect(FileManager.default.fileExists(atPath: old.path))
    }

    @Test func nothingToMoveIsFine() {
        let home = temporaryDirectory()
        HookLog.moveOldUpdateLog(home: home.path)
        #expect(!FileManager.default.fileExists(atPath: home.path))
    }
}

@Suite struct HookLogScreenTests {
    @Test func aSettingsTabOpenWritesOneScreenLine() throws {
        let dir = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = RollingLog(directory: dir, now: fixedNow)
        HookLog.withLog(log) {
            HookLog.opened(.general)
        }
        #expect(log.tail(50) == ["2026-11-03T10:00:00Z screen settingsGeneral"])
    }

    @Test func everySettingsTabHasItsScreen() {
        #expect(SettingsTabID.allCases.map { HookLog.Screen($0) }
            == [.settingsGeneral, .settingsPanel, .settingsQueue, .settingsNotifications, .settingsAgents])
    }

    @Test func theTrackerLogsAScreenOnceUntilAnotherOpensOrItResets() {
        var tracker = HookLog.ScreenTracker()
        var opened: [Bool] = []
        opened.append(tracker.open(.settingsGeneral))
        opened.append(tracker.open(.settingsGeneral))
        opened.append(tracker.open(.settingsQueue))
        tracker.reset()
        opened.append(tracker.open(.settingsQueue))
        #expect(opened == [true, false, true, true])
    }

    @Test func aScopedLogIsSeenByChildTasksOnly() async throws {
        let dir = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = RollingLog(directory: dir, now: fixedNow)
        await HookLog.withLog(log) {
            await Task { HookLog.action(.copy) }.value
        }
        #expect(log.tail(50) == ["2026-11-03T10:00:00Z action copy"])
    }
}
