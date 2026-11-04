import Foundation
import Testing
@testable import RelayCore

private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory.appending(path: "hook-crash-tests-\(UUID().uuidString)")
}

private func fixture(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "ips", subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

private let started = Date(timeIntervalSince1970: 1_793_600_000)

private func marker(pid: Int32 = 4242, version: String = "0.11.0", clean: Bool = false) -> RunMarker {
    RunMarker(pid: pid, version: version, started: started, clean: clean)
}

// MARK: - Run marker

@Suite struct RunMarkerTests {
    @Test func theFirstRunHasNoPreviousMarker() throws {
        let dir = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "run-state.json")
        #expect(try RunMarkerStore.begin(marker(), at: url) == nil)
        #expect(RunMarkerStore.uncleanEnd(nil, currentPID: 1, isRunningHook: { _ in false }) == nil)
    }

    @Test func aCleanQuitIsNotACrash() throws {
        let dir = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "run-state.json")
        _ = try RunMarkerStore.begin(marker(pid: 10), at: url)
        try RunMarkerStore.markClean(at: url)
        let previous = try RunMarkerStore.begin(marker(pid: 11), at: url)
        #expect(previous == marker(pid: 10, clean: true))
        #expect(RunMarkerStore.uncleanEnd(previous, currentPID: 11, isRunningHook: { _ in false }) == nil)
    }

    @Test func anUncleanRunIsReported() throws {
        let dir = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "run-state.json")
        _ = try RunMarkerStore.begin(marker(pid: 10), at: url)
        let previous = try RunMarkerStore.begin(marker(pid: 11, version: "0.12.0"), at: url)
        #expect(previous == marker(pid: 10))
        #expect(RunMarkerStore.uncleanEnd(previous, currentPID: 11, isRunningHook: { _ in false }) == marker(pid: 10))
        // The new run's marker starts unclean.
        let stored = try JSONDecoder.marker.decode(RunMarker.self, from: Data(contentsOf: url))
        #expect(stored.pid == 11 && !stored.clean && stored.version == "0.12.0")
    }

    @Test func aPidStillRunningAsHookCountsAsClean() {
        // A second copy started while the first is up: the first one didn't crash.
        #expect(RunMarkerStore.uncleanEnd(marker(pid: 10), currentPID: 11, isRunningHook: { $0 == 10 }) == nil)
        // Our own pid in an old marker (pid reuse) is never "still running".
        #expect(RunMarkerStore.uncleanEnd(marker(pid: 11), currentPID: 11, isRunningHook: { _ in true }) == marker(pid: 11))
    }

    @Test func aGarbledMarkerIsTreatedAsNone() throws {
        let dir = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "run-state.json")
        try PrivateFile.write(Data("not json".utf8), to: url)
        #expect(try RunMarkerStore.begin(marker(), at: url) == nil)
    }

    @Test func markCleanWithNoMarkerDoesNothing() throws {
        let dir = temporaryDirectory()
        try RunMarkerStore.markClean(at: dir.appending(path: "run-state.json"))
        #expect(!FileManager.default.fileExists(atPath: dir.path))
    }
}

// MARK: - .ips parser

@Suite struct IPSReportTests {
    @Test func aSymbolicatedReport() throws {
        let report = try IPSReport.parse(fixture("crash-symbolicated"))
        #expect(report.exception == "EXC_BAD_ACCESS")
        #expect(report.signal == "SIGSEGV")
        #expect(report.termination == "Segmentation fault: 11")
        // Only Hook's own frames, from the crashed thread.
        #expect(report.appFrames.map(\.symbol) == ["SettingsWindow.open(tab:)", "AppDelegate.showSettings(_:)",
                                                   "closure #1 in PanelShell.perform(_:)", "main"])
        #expect(report.appFrames.first?.offset == 212)
        #expect(report.appFrames.first?.imageOffset == 200100)
        #expect(report.symbolicated)
    }

    @Test func anUnsymbolicatedReport() throws {
        let report = try IPSReport.parse(fixture("crash-unsymbolicated"))
        #expect(report.exception == "EXC_BREAKPOINT")
        #expect(report.signal == "SIGTRAP")
        #expect(report.termination == "Trace/BPT trap: 5")
        #expect(report.appFrames.map(\.imageOffset) == [284280, 151000, 120000, 100000])
        #expect(report.appFrames.allSatisfy { $0.symbol == nil })
        #expect(!report.symbolicated)
    }

    @Test func atMostEightFrames() throws {
        var frames = (0..<20).map { #"{"imageOffset":\#($0),"symbol":"F\#($0)()","symbolLocation":1,"imageIndex":0}"# }
        frames.insert(#"{"imageOffset":1,"symbol":"objc_msgSend","imageIndex":1}"#, at: 0)
        let text = #"{"app_name":"Hook","bug_type":"309"}"# + "\n"
            + #"{"exception":{"type":"EXC_CRASH","signal":"SIGABRT"},"faultingThread":0,"threads":[{"triggered":true,"frames":["#
            + frames.joined(separator: ",")
            + #"]}],"usedImages":[{"name":"Hook"},{"name":"libobjc.A.dylib"}]}"#
        let report = try IPSReport.parse(Data(text.utf8))
        #expect(report.appFrames.count == 8)
        #expect(report.appFrames.first?.symbol == "F0()")
        #expect(report.termination == nil)
    }

    @Test func aGarbledFileThrows() {
        #expect(throws: IPSReport.ParseError.self) { try IPSReport.parse(Data("hello".utf8)) }
        #expect(throws: IPSReport.ParseError.self) { try IPSReport.parse(Data("{}\n{not json".utf8)) }
        #expect(throws: IPSReport.ParseError.self) { try IPSReport.parse(Data("{}\n{\"threads\":[]}".utf8)) }
    }

    @Test func aGarbledReportStillCountsAsACrashWithNoReport() throws {
        let dir = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appending(path: "Hook-2026-11-02-221409.ips")
        try Data("garbled".utf8).write(to: file)
        let found = CrashFinder.find(previous: marker(), reports: dir, macOS: "15.6", cpu: "arm64")
        #expect(found.report == nil)
        #expect(found.hookVersion == "0.11.0")
        #expect(found.title.hasPrefix("Hook quit unexpectedly"))
    }

    @Test func newestSkipsOlderFilesAndOtherApps() throws {
        let dir = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        func make(_ name: String, _ mtime: Date) throws -> URL {
            let url = dir.appending(path: name)
            try Data("x".utf8).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: url.path)
            return url
        }
        _ = try make("Hook-2026-11-01-100000.ips", started.addingTimeInterval(-60))      // before the run
        let wanted = try make("Hook-2026-11-02-221409.ips", started.addingTimeInterval(600))
        _ = try make("Hook-2026-11-02-200000.ips", started.addingTimeInterval(300))      // older than wanted
        _ = try make("Hooker-2026-11-02-230000.ips", started.addingTimeInterval(900))    // another app
        _ = try make("Safari-2026-11-02-230000.ips", started.addingTimeInterval(900))
        _ = try make("Hook-2026-11-02-230000.diag", started.addingTimeInterval(900))     // not an .ips
        #expect(IPSReport.newest(in: dir, after: started)?.lastPathComponent == wanted.lastPathComponent)
        #expect(IPSReport.newest(in: dir, after: started.addingTimeInterval(1000)) == nil)
        #expect(IPSReport.newest(in: dir.appending(path: "missing"), after: started) == nil)
    }
}

// MARK: - Summary and signature

@Suite struct CrashSummaryTests {
    private func summary(_ report: IPSReport?, version: String = "0.11.0") -> CrashSummary {
        CrashSummary(report: report, hookVersion: version, macOS: "15.6", cpu: "arm64", when: started)
    }

    @Test func theSignatureIsStableAcrossParses() throws {
        let one = summary(try IPSReport.parse(fixture("crash-symbolicated")))
        let two = summary(try IPSReport.parse(fixture("crash-symbolicated")))
        #expect(one.signature == two.signature)
        #expect(one.signature.range(of: "^[0-9a-f]{12}$", options: .regularExpression) != nil)
    }

    @Test func offsetsDontChangeIt() throws {
        let report = try IPSReport.parse(fixture("crash-symbolicated"))
        var moved = report
        moved.appFrames = moved.appFrames.map { IPSReport.Frame(symbol: $0.symbol, offset: ($0.offset ?? 0) + 40, imageOffset: $0.imageOffset + 4096) }
        #expect(summary(report).signature == summary(moved).signature)
        // A symbol that carries its own "+ 52" suffix hashes like the bare one.
        var suffixed = report
        suffixed.appFrames[0].symbol = "SettingsWindow.open(tab:) + 52"
        #expect(summary(report).signature == summary(suffixed).signature)
        // A new Hook version keeps a symbolicated signature.
        #expect(summary(report).signature == summary(report, version: "0.12.0").signature)
    }

    @Test func aDifferentExceptionOrFrameChangesIt() throws {
        let report = try IPSReport.parse(fixture("crash-symbolicated"))
        var other = report
        other.exception = "EXC_CRASH"
        #expect(summary(report).signature != summary(other).signature)
        var frame = report
        frame.appFrames[1].symbol = "AppDelegate.showQueue(_:)"
        #expect(summary(report).signature != summary(frame).signature)
        // Below the top three, frames don't count.
        var deep = report
        deep.appFrames[3].symbol = "other"
        #expect(summary(report).signature == summary(deep).signature)
    }

    @Test func unsymbolicatedFramesUseOffsetsAndTheVersion() throws {
        let report = try IPSReport.parse(fixture("crash-unsymbolicated"))
        #expect(summary(report).signature == summary(report).signature)
        #expect(summary(report).signature != summary(report, version: "0.12.0").signature)
        var moved = report
        moved.appFrames[0].imageOffset += 4
        #expect(summary(report).signature != summary(moved).signature)
    }

    @Test func titles() throws {
        let symbolicated = summary(try IPSReport.parse(fixture("crash-symbolicated")))
        #expect(symbolicated.title == "Hook crash: EXC_BAD_ACCESS in SettingsWindow.open (\(symbolicated.signature))")
        let bare = summary(try IPSReport.parse(fixture("crash-unsymbolicated")))
        #expect(bare.title == "Hook crash: EXC_BREAKPOINT in Hook +0x45678 (\(bare.signature))")
        let none = summary(nil)
        #expect(none.title == "Hook quit unexpectedly (\(none.signature))")
    }

    @Test func noReportStillHasASignature() {
        #expect(summary(nil).signature.count == 12)
        #expect(summary(nil).signature != summary(nil, version: "0.12.0").signature)
    }
}

// MARK: - The report text

@Suite struct CrashReportTextTests {
    private let log = [
        "2026-11-02T22:13:58Z launch hook=0.11.0 macos=15.6 cpu=arm64",
        "2026-11-02T22:14:07Z error type=Mailbox status=401 route=asks/{id}/reply message=\"refused\"",
    ]

    @Test func theBodyHoldsOnlyTheAllowedFields() throws {
        let s = CrashSummary(report: try IPSReport.parse(fixture("crash-symbolicated")),
                             hookVersion: "0.11.0", macOS: "15.6", cpu: "arm64", when: started)
        let body = CrashReportText.body(s, source: "Pond", pond: "1.1.0", log: log, home: "/Users/me", user: "me")
        #expect(body == """
        \(s.title)
        Crash signature: hook-crash-\(s.signature)

        Hook       0.11.0 (arm64) · macOS 15.6
        Source     Pond 1.1.0
        Exception  EXC_BAD_ACCESS (SIGSEGV)
        Reason     Segmentation fault: 11
        Frames     SettingsWindow.open(tab:) +212
                   AppDelegate.showSettings(_:) +48
                   closure #1 in PanelShell.perform(_:) +96
                   main +20

        Last 2 log lines
        2026-11-02T22:13:58Z launch hook=0.11.0 macos=15.6 cpu=arm64
        2026-11-02T22:14:07Z error type=Mailbox status=401 route=asks/{id}/reply message="refused"
        """)
        // Nothing from the .ips beyond those fields: no paths, no ids, no other threads.
        #expect(!body.contains("/Users/me"))
        #expect(!body.contains("Store.poll"))
        #expect(!body.contains("objc_msgSend"))
        #expect(!body.contains("00000000-"))
    }

    @Test func aPathInAFrameOrTheLogComesOutAsTilde() throws {
        var report = try IPSReport.parse(fixture("crash-symbolicated"))
        report.appFrames[0].symbol = "Bundle.load(/Users/me/Library/Application Support/Relay/x)"
        let s = CrashSummary(report: report, hookVersion: "0.11.0", macOS: "15.6", cpu: "arm64", when: started)
        let body = CrashReportText.body(s, source: "This Mac", pond: nil,
                                        log: ["error message=\"at /Users/me/x via https://pond.example.com\""],
                                        home: "/Users/me", user: "me")
        #expect(body.contains("Bundle.load(~/Library/Application Support/Relay/x)"))
        #expect(body.contains("error message=\"at ~/x via <host>\""))
        #expect(body.contains("Source     This Mac\n"))
        #expect(!body.contains("/Users/me"))
    }

    @Test func noReportSaysSo() {
        let s = CrashSummary(report: nil, hookVersion: "0.11.0", macOS: "15.6", cpu: "arm64", when: started)
        let body = CrashReportText.body(s, source: "This Mac", pond: nil, log: [], home: "/Users/me", user: "me")
        #expect(body.contains("Exception  none: no crash report (a hang, a force quit or a kill)"))
        #expect(!body.contains("Frames"))
        #expect(body.hasSuffix("Last 0 log lines"))
    }

    @Test func atMostFortyLogLines() {
        let s = CrashSummary(report: nil, hookVersion: "0.11.0", macOS: "15.6", cpu: "arm64", when: started)
        let lines = (0..<60).map { "line \($0)" }
        let body = CrashReportText.body(s, source: "This Mac", pond: nil, log: lines, home: "/Users/me", user: "me")
        #expect(body.contains("Last 40 log lines\nline 20\n"))
        #expect(!body.contains("line 19\n"))
    }

    @Test func theSignatureLine() {
        #expect(CrashReportText.signatureLine("a3f9c2e17b04") == "Crash signature: hook-crash-a3f9c2e17b04")
    }
}

// MARK: - Handled signatures and the decision

@Suite struct CrashDecisionTests {
    private let s = CrashSummary(report: nil, hookVersion: "0.11.0", macOS: "15.6", cpu: "arm64", when: started)

    @Test func handledKeepsTheLastFifty() throws {
        let defaults = try #require(UserDefaults(suiteName: "hook-crash-tests-\(UUID().uuidString)"))
        var handled = HandledCrashes.load(defaults)
        for i in 0..<60 { handled.add(String(format: "%012x", i)) }
        handled.save(defaults)
        let back = HandledCrashes.load(defaults)
        #expect(back.signatures.count == 50)
        #expect(!back.contains(String(format: "%012x", 9)))
        #expect(back.contains(String(format: "%012x", 10)))
        #expect(back.contains(String(format: "%012x", 59)))
        // Adding one again moves it to the end and doesn't duplicate it.
        var again = back
        again.add(String(format: "%012x", 10))
        #expect(again.signatures.count == 50)
        #expect(again.signatures.last == String(format: "%012x", 10))
    }

    @Test func offRecordsNothing() {
        #expect(CrashDecision.decide(s, setting: .off, target: .pond, pondOffered: true, handled: HandledCrashes()) == .ignore)
    }

    @Test func aHandledSignatureIsRaisedOnce() {
        var handled = HandledCrashes()
        handled.add(s.handledKey)
        #expect(CrashDecision.decide(s, setting: .ask, target: .github, pondOffered: false, handled: handled) == .ignore)
    }

    @Test func automaticSendsOnlyToTheOwnersPond() {
        #expect(CrashDecision.decide(s, setting: .auto, target: .pond, pondOffered: true, handled: HandledCrashes()) == .sendToPond)
        // GitHub always needs a review, and a saved Pond without a key reads as GitHub.
        #expect(CrashDecision.decide(s, setting: .auto, target: .github, pondOffered: true, handled: HandledCrashes()) == .offer)
        #expect(CrashDecision.decide(s, setting: .auto, target: .pond, pondOffered: false, handled: HandledCrashes()) == .offer)
        #expect(CrashDecision.decide(s, setting: .ask, target: .pond, pondOffered: true, handled: HandledCrashes()) == .offer)
    }

    @Test func theTargetFallsBackToGitHub() {
        #expect(CrashTarget.pond.effective(pondOffered: false) == .github)
        #expect(CrashTarget.pond.effective(pondOffered: true) == .pond)
        #expect(CrashTarget.github.effective(pondOffered: true) == .github)
    }
}

// MARK: - Option B

private final class SpyReporter: CrashReporter, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [String] = []
    var calls: [String] { lock.withLock { _calls } }
    func start(consent: Bool) { lock.withLock { _calls.append("start(\(consent))") } }
    func record(_ summary: CrashSummary) { lock.withLock { _calls.append("record") } }
    func stop() { lock.withLock { _calls.append("stop") } }
}

@Suite struct CrashReporterTests {
    @Test func noCrashReporterIsANoOp() {
        let reporter = NoCrashReporter()
        reporter.start(consent: true)
        reporter.record(CrashSummary(report: nil, hookVersion: "0.12.0", macOS: "15.6", cpu: "arm64", when: started))
        reporter.stop()
    }

    @Test func nothingStartsWhenTheSettingIsOff() {
        let spy = SpyReporter()
        CrashReporterControl.apply(.off, to: spy)
        #expect(spy.calls == ["stop"])
        let other = SpyReporter()
        CrashReporterControl.apply(.ask, to: other)
        CrashReporterControl.apply(.auto, to: other)
        #expect(other.calls == ["start(true)", "start(true)"])
    }

    @Test func aCrashIsRecordedOnlyWhenNotOff() {
        let s = CrashSummary(report: nil, hookVersion: "0.12.0", macOS: "15.6", cpu: "arm64", when: started)
        let spy = SpyReporter()
        CrashReporterControl.record(s, setting: .off, to: spy)
        #expect(spy.calls.isEmpty)
        CrashReporterControl.record(s, setting: .ask, to: spy)
        #expect(spy.calls == ["record"])
    }
}
