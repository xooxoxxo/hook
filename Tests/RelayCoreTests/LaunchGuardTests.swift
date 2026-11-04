import Foundation
import Testing
@testable import RelayCore

private let t0 = Date(timeIntervalSince1970: 1_793_600_000)

private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory.appending(path: "hook-guard-tests-\(UUID().uuidString)")
}

private func marker(pid: Int32, clean: Bool = false) -> RunMarker {
    RunMarker(pid: pid, version: "0.12.0", started: t0, clean: clean)
}

private let nobody: @Sendable (Int32) -> Bool = { _ in false }

/// The loop on macOS 27: each start found the last crash, offered it, and died while offering,
/// so the next start found it again.
@Suite struct CrashOfferGuardTests {
    private let record = CrashOfferRecord(key: "7e08a28a2481", signature: "7e08a28a2481", pid: 10, at: t0)

    @Test func aRunThatDiedWhileOfferingBacksOff() {
        #expect(CrashOfferGuard.verdict(previous: marker(pid: 10), record: record) == .diedOffering(record))
        let plan = StartPlan.make(previous: marker(pid: 10), history: [], offer: record, request: nil,
                                   currentPID: 11, isRunningHook: nobody)
        #expect(plan.backOff == record)
        #expect(!plan.offers)
        #expect(plan.lastRun == .crashed(marker(pid: 10)))
    }

    @Test func anOfferThatLivedOrAnotherRunsOfferIsClear() {
        var survived = record
        survived.survived = true
        #expect(CrashOfferGuard.verdict(previous: marker(pid: 10), record: survived) == .clear)
        // The run quit cleanly after offering: it didn't die of it.
        #expect(CrashOfferGuard.verdict(previous: marker(pid: 10, clean: true), record: record) == .clear)
        // The offer was made by an earlier run, not the one that died.
        #expect(CrashOfferGuard.verdict(previous: marker(pid: 12), record: record) == .clear)
        #expect(CrashOfferGuard.verdict(previous: nil, record: record) == .clear)
        #expect(CrashOfferGuard.verdict(previous: marker(pid: 10), record: nil) == .clear)
        #expect(StartPlan.make(previous: marker(pid: 12), history: [], offer: record, request: nil, currentPID: 13,
                                isRunningHook: nobody).offers)
    }

    @Test func theRecordIsWrittenAndRead() throws {
        let dir = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = CrashOfferGuard.url(dataDirectory: dir)
        #expect(url.lastPathComponent == "crash-offer.json")
        #expect(CrashOfferGuard.read(url) == nil)
        try CrashOfferGuard.write(record, to: url)
        #expect(CrashOfferGuard.read(url) == record)
        try PrivateFile.write(Data("x".utf8), to: url)
        #expect(CrashOfferGuard.read(url) == nil)
    }
}

@Suite struct LaunchHistoryTests {
    @Test func threeEarlyDeathsInARowStartSafe() {
        let died = (1...3).map { LaunchRecord(pid: Int32($0), started: t0) }
        #expect(LaunchHistory.safeMode(died))
        #expect(!LaunchHistory.safeMode(Array(died.prefix(2))))
        // Any of the three living past the window, or quitting, clears it.
        var lived = died
        lived[1].survived = true
        #expect(!LaunchHistory.safeMode(lived))
        var quit = died
        quit[2].clean = true
        #expect(!LaunchHistory.safeMode(quit))
        // Only the last three count.
        #expect(LaunchHistory.safeMode([LaunchRecord(pid: 9, started: t0, survived: true)] + died))
        #expect(StartPlan.make(previous: nil, history: died, offer: nil, request: nil, currentPID: 4,
                                isRunningHook: nobody).safeMode)
        #expect(!StartPlan.make(previous: nil, history: died, offer: nil, request: nil, currentPID: 4,
                                 isRunningHook: nobody).offers)
    }

    @Test func theFileKeepsTheLastRunsAndMarksThem() throws {
        let dir = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = LaunchHistory.url(dataDirectory: dir)
        #expect(url.lastPathComponent == "launches.json")
        for pid in 1...10 {
            let before = try LaunchHistory.begin(LaunchRecord(pid: Int32(pid), started: t0), at: url)
            #expect(before.last?.pid == (pid == 1 ? nil : Int32(pid - 1)))
        }
        #expect(LaunchHistory.read(url).map(\.pid) == Array(3...10).map(Int32.init))
        try LaunchHistory.markSurvived(pid: 10, at: url)
        try LaunchHistory.markClean(pid: 9, at: url)
        try LaunchHistory.markClean(pid: 999, at: url)   // not there: nothing changes
        let runs = LaunchHistory.read(url)
        #expect(runs.last == LaunchRecord(pid: 10, started: t0, survived: true))
        #expect(runs[runs.count - 2] == LaunchRecord(pid: 9, started: t0, clean: true))
        try PrivateFile.write(Data("garbled".utf8), to: url)
        #expect(LaunchHistory.read(url).isEmpty)
        #expect(try LaunchHistory.begin(LaunchRecord(pid: 1, started: t0), at: url).isEmpty)
    }
}
