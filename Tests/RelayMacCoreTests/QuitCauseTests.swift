import Foundation
import Testing
@testable import RelayCore
@testable import RelayMacCore

private let started = Date(timeIntervalSince1970: 1_793_600_000)

private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory.appending(path: "hook-quit-tests-\(UUID().uuidString)")
}

private func marker(pid: Int32 = 10, clean: Bool = false, cause: QuitCause? = nil) -> RunMarker {
    RunMarker(pid: pid, version: "0.14.0", started: started, clean: clean, cause: cause)
}

/// 0.14: every quit says why, and a quit nobody expected is raised like a crash.
@Suite struct QuitCauseTests {
    @Test func whichCausesAreExpected() {
        for kind in [QuitCause.Kind.user, .updater, .installer, .duplicate, .logout, .restart, .shutdown, .powerOff] {
            #expect(QuitCause(kind).expected, "\(kind)")
        }
        for kind in [QuitCause.Kind.signal, .appleEvent, .code] {
            #expect(!QuitCause(kind).expected, "\(kind)")
        }
        #expect(QuitCause.Kind.allCases.count == 11)
    }

    @Test func theBarsText() {
        #expect(QuitCause.signal("TERM", pid: 1, process: "launchd").text == "SIGTERM from launchd (pid 1)")
        #expect(QuitCause.signal("HUP", pid: nil, process: nil).text == "SIGHUP from another process")
        #expect(QuitCause.signal("TERM", pid: 812, process: nil).text == "SIGTERM from pid 812")
        #expect(QuitCause(.appleEvent, pid: 400, process: "Activity Monitor").text
            == "a quit request from Activity Monitor (pid 400)")
        #expect(QuitCause(.appleEvent).text == "a quit request from another app")
        #expect(QuitCause.code("watchdog").text == "Hook's own code (watchdog)")
        #expect(QuitCause.user("menu").text == "you quit it")
    }

    @Test func aSendersNameCarriesNothingButPlainCharacters() {
        let cause = QuitCause.signal("TERM\n", pid: -3, process: "evil\"name\n=x; /Users/me/run.sh and a very long tail")
        #expect(cause.detail == "TERM")
        #expect(cause.pid == nil)
        #expect(cause.process == "evilnamex Usersmerun.sh and a ve")
    }

    @Test func theLogFields() {
        let quote: (String) -> String = { "\"\($0)\"" }
        #expect(QuitCause.signal("TERM", pid: 1, process: "launchd").logFields(quote: quote)
            == #"signal sig=TERM pid=1 from="launchd""#)
        #expect(QuitCause.user("menu").logFields(quote: quote) == "user via=menu")
        #expect(QuitCause(.installer, pid: 77).logFields(quote: quote) == "installer pid=77")
        #expect(QuitCause(.logout).logFields(quote: quote) == "logout")
        #expect(QuitCause(.appleEvent, process: "Activity Monitor").logFields(quote: quote)
            == #"appleEvent from="Activity Monitor""#)
    }

    @Test func theQuitAppleEventsReason() {
        func reason(_ s: String) -> UInt32 { QuitCause.fourCC(s) }
        #expect(reason("logo") == 0x6C6F_676F)
        #expect(QuitCause.appleEvent(reason: reason("logo"), senderPID: 90, sender: "loginwindow").kind == .logout)
        #expect(QuitCause.appleEvent(reason: reason("rlgo"), senderPID: nil, sender: nil).kind == .logout)
        #expect(QuitCause.appleEvent(reason: reason("rrst"), senderPID: nil, sender: nil).kind == .restart)
        #expect(QuitCause.appleEvent(reason: reason("rest"), senderPID: nil, sender: nil).kind == .restart)
        #expect(QuitCause.appleEvent(reason: reason("rsdn"), senderPID: nil, sender: nil).kind == .shutdown)
        #expect(QuitCause.appleEvent(reason: reason("shut"), senderPID: nil, sender: nil).kind == .shutdown)
        #expect(QuitCause.appleEvent(reason: nil, senderPID: 400, sender: "Activity Monitor")
            == QuitCause(.appleEvent, pid: 400, process: "Activity Monitor"))
    }

    @Test func hookLogLines() {
        func line(_ event: HookLog.Event) -> String { event.line(home: "/Users/me", user: "me") }
        #expect(line(.quit(clean: true, cause: .user("menu"))) == "quit clean=true cause=user via=menu")
        #expect(line(.quit(clean: true, cause: .signal("TERM", pid: 1, process: "launchd")))
            == #"quit clean=true cause=signal sig=TERM pid=1 from="launchd""#)
        // A sender named after the user is redacted like any other value.
        #expect(line(.quit(clean: true, cause: .signal("HUP", pid: 9, process: "me-tool")))
            == #"quit clean=true cause=signal sig=HUP pid=9 from="<user>-tool""#)
        #expect(line(.lastRun(clean: false, cause: QuitCause(.installer, pid: 77)))
            == "last-run clean=false cause=installer pid=77")
        #expect(line(.crashFound(signature: "a3f9c2e17b04", report: false, closed: .signal))
            == "crash signature=a3f9c2e17b04 report=false closed=signal")
        #expect(line(.diagnostic(kind: "hang", detail: "duration=4.2s version=0.14.0"))
            == #"diagnostic hang "duration=4.2s version=0.14.0""#)
    }
}

@Suite struct QuitMarkerTests {
    @Test func aCleanQuitKeepsItsCauseAndEnd() throws {
        let dir = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = RunMarkerStore.url(dataDirectory: dir)
        _ = try RunMarkerStore.begin(marker(pid: 10), at: url)
        let ended = started.addingTimeInterval(60)
        try RunMarkerStore.markClean(at: url, pid: 10, cause: .signal("TERM", pid: 1, process: "launchd"), ended: ended)
        let back = try #require(RunMarkerStore.read(url))
        #expect(back == marker(pid: 10, clean: true, cause: .signal("TERM", pid: 1, process: "launchd")).with(ended: ended))
    }

    @Test func anotherRunsMarkerIsLeftAlone() throws {
        let dir = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = RunMarkerStore.url(dataDirectory: dir)
        _ = try RunMarkerStore.begin(marker(pid: 11), at: url)
        try RunMarkerStore.markClean(at: url, pid: 10, cause: .user("menu"))
        #expect(RunMarkerStore.read(url)?.clean == false)
    }

    @Test func aMarkerFromBefore014StillReads() throws {
        let dir = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = RunMarkerStore.url(dataDirectory: dir)
        try PrivateFile.write(Data(#"{"clean":false,"pid":4242,"started":"2026-11-02T10:00:00Z","version":"0.13.0"}"#.utf8), to: url)
        let previous = try #require(try RunMarkerStore.begin(marker(pid: 11), at: url))
        #expect(previous.version == "0.13.0" && !previous.clean && previous.cause == nil)
        #expect(LastRun.classify(previous, currentPID: 11, isRunningHook: { _ in false }, request: nil) == .crashed(previous))
        // An old clean marker has no cause: nothing to raise.
        var clean = previous
        clean.clean = true
        #expect(LastRun.classify(clean, currentPID: 11, isRunningHook: { _ in false }, request: nil) == .fine)
    }

    @Test func howTheLastRunEnded() {
        let none: (Int32) -> Bool = { _ in false }
        #expect(LastRun.classify(nil, currentPID: 11, isRunningHook: none, request: nil) == .fine)
        #expect(LastRun.classify(marker(clean: true, cause: .user("menu")), currentPID: 11, isRunningHook: none,
                                 request: nil) == .fine)
        #expect(LastRun.classify(marker(clean: true, cause: QuitCause(.shutdown)), currentPID: 11, isRunningHook: none,
                                 request: nil) == .fine)
        let term = QuitCause.signal("TERM", pid: 1, process: "launchd")
        #expect(LastRun.classify(marker(clean: true, cause: term), currentPID: 11, isRunningHook: none, request: nil)
            == .closed(marker(clean: true, cause: term), term))
        #expect(LastRun.classify(marker(), currentPID: 11, isRunningHook: none, request: nil) == .crashed(marker()))
        // Still running as Hook (a second copy): fine.
        #expect(LastRun.classify(marker(), currentPID: 11, isRunningHook: { $0 == 10 }, request: nil) == .fine)
        // install.sh asked, then had to force-quit: logged, not raised.
        let asked = QuitRequest(cause: QuitCause(.installer, pid: 77), at: started.addingTimeInterval(30))
        #expect(LastRun.classify(marker(), currentPID: 11, isRunningHook: none, request: asked)
            == .forceQuit(marker(), QuitCause(.installer, pid: 77)))
        // A request older than the run is someone else's.
        let stale = QuitRequest(cause: QuitCause(.installer), at: started.addingTimeInterval(-30))
        #expect(LastRun.classify(marker(), currentPID: 11, isRunningHook: none, request: stale) == .crashed(marker()))
    }
}

@Suite struct QuitRequestTests {
    @Test func theInstallersFile() throws {
        let request = try #require(QuitRequest.parse(Data(#"{"by":"installer","pid":812,"at":1793600030}"#.utf8)))
        #expect(request.cause == QuitCause(.installer, pid: 812))
        #expect(request.at == started.addingTimeInterval(30))
        #expect(QuitRequest.parse(Data(#"{"by":"updater","at":1793600030}"#.utf8))?.cause == QuitCause(.updater))
        #expect(QuitRequest.parse(Data(#"{"by":"user","at":1793600030}"#.utf8)) == nil)
        #expect(QuitRequest.parse(Data(#"{"by":"installer"}"#.utf8)) == nil)
        #expect(QuitRequest.parse(Data("installer".utf8)) == nil)
    }

    @Test func freshness() {
        let request = QuitRequest(cause: QuitCause(.installer), at: started)
        #expect(request.isFresh(now: started.addingTimeInterval(5)))
        #expect(request.isFresh(now: started.addingTimeInterval(-2)))
        #expect(!request.isFresh(now: started.addingTimeInterval(QuitRequest.freshFor + 1)))
        #expect(!request.isFresh(now: started.addingTimeInterval(-60)))
    }

    @Test func takeReadsOnceAndRemovesTheFile() throws {
        let dir = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = QuitRequest.url(dataDirectory: dir)
        #expect(url.lastPathComponent == "quit-request.json")
        try PrivateFile.write(Data(#"{"by":"updater","pid":5,"at":1793600030}"#.utf8), to: url)
        #expect(QuitRequest.take(dataDirectory: dir)?.cause == QuitCause(.updater, pid: 5))
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(QuitRequest.take(dataDirectory: dir) == nil)
        // A garbled file still goes.
        try PrivateFile.write(Data("x".utf8), to: url)
        #expect(QuitRequest.take(dataDirectory: dir) == nil)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
}

@Suite struct ClosedRunTests {
    private let term = QuitCause.signal("TERM", pid: 1, process: "launchd")

    private func closed(_ cause: QuitCause, run: Date = started) -> CrashSummary {
        CrashSummary(report: nil, hookVersion: "0.14.0", macOS: "15.6", cpu: "arm64", when: run, closed: cause, run: run)
    }

    @Test func aClosedRunHasItsOwnTitleAndSignature() {
        let s = closed(term)
        #expect(s.title == "Hook was closed: SIGTERM from launchd (pid 1) (\(s.signature))")
        #expect(s.signature.count == 12)
        let noReport = CrashSummary(report: nil, hookVersion: "0.14.0", macOS: "15.6", cpu: "arm64", when: started)
        #expect(s.signature != noReport.signature)
        #expect(s.signature != closed(QuitCause(.appleEvent, process: "Activity Monitor")).signature)
        // The sender's pid changes run to run; the signature doesn't follow it.
        #expect(s.signature == closed(.signal("TERM", pid: 2, process: "launchd")).signature)
    }

    @Test func aRunWithoutAReportIsHandledOnlyForThatRun() {
        let first = CrashSummary(report: nil, hookVersion: "0.14.0", macOS: "15.6", cpu: "arm64", when: started,
                                 run: started)
        let next = CrashSummary(report: nil, hookVersion: "0.14.0", macOS: "15.6", cpu: "arm64",
                                when: started.addingTimeInterval(3600), run: started.addingTimeInterval(3600))
        #expect(first.signature == next.signature)
        #expect(first.handledKey != next.handledKey)
        var handled = HandledCrashes()
        handled.add(first.handledKey)
        #expect(CrashDecision.decide(first, setting: .ask, target: .github, pondOffered: false, handled: handled) == .ignore)
        #expect(CrashDecision.decide(next, setting: .ask, target: .github, pondOffered: false, handled: handled) == .offer)
        // A closed run likewise.
        handled.add(closed(term).handledKey)
        #expect(CrashDecision.decide(closed(term, run: started.addingTimeInterval(60)), setting: .ask, target: .github,
                                     pondOffered: false, handled: handled) == .offer)
    }

    @Test func aCrashReportIsStillHandledBySignature() throws {
        let report = IPSReport(exception: "EXC_BAD_ACCESS", signal: "SIGSEGV", termination: nil,
                               appFrames: [IPSReport.Frame(symbol: "A.b()", offset: 4, imageOffset: 16)])
        let s = CrashSummary(report: report, hookVersion: "0.14.0", macOS: "15.6", cpu: "arm64", when: started, run: started)
        #expect(s.handledKey == s.signature)
        // A report wins over a closed cause.
        #expect(CrashSummary(report: report, hookVersion: "0.14.0", macOS: "15.6", cpu: "arm64", when: started,
                             closed: term).closed == nil)
    }

    @Test func theReportSaysWhatClosedIt() {
        let s = closed(term)
        let body = CrashReportText.body(s, source: "This Mac", pond: nil, log: [], home: "/Users/me", user: "me")
        #expect(body.hasPrefix("Hook was closed: SIGTERM from launchd (pid 1) (\(s.signature))\n"))
        #expect(body.contains("Exception  none: Hook was closed, not crashed\nClosed by  SIGTERM from launchd (pid 1)\n"))
        let ask = try? JSONSerialization.jsonObject(with: BugAsk.instructable(s, body: body)) as? [String: Any]
        #expect(ask?["why"] as? String == BugAsk.closedWhy)
    }
}

extension RunMarker {
    func with(ended: Date) -> RunMarker {
        var copy = self
        copy.ended = ended
        return copy
    }
}

@Suite struct MetricDiagnosticsTests {
    private func line(_ event: HookLog.Event) -> String { event.line(home: "/Users/me", user: "me") }

    @Test func eachPayloadIsOneLine() {
        #expect(line(MetricDiagnostics.crash(exceptionType: 6, exceptionCode: 1, signal: 5,
                                             reason: "Namespace SIGNAL, Code 5\nat /Users/me/x", version: "0.14.0"))
            == #"diagnostic crash "exception=6 code=1 signal=5 version=0.14.0 reason=Namespace SIGNAL, Code 5 at ~/x""#)
        #expect(line(MetricDiagnostics.crash(exceptionType: nil, exceptionCode: nil, signal: nil, reason: nil,
                                             version: nil)) == #"diagnostic crash """#)
        #expect(line(MetricDiagnostics.hang(seconds: 4.25, version: "0.14.0"))
            == #"diagnostic hang "duration=4.2s version=0.14.0""#)
        #expect(line(MetricDiagnostics.cpuException(cpuSeconds: 92.5, sampledSeconds: 180, version: "0.14.0"))
            == #"diagnostic cpu "cpu=92.5s over=180.0s version=0.14.0""#)
        #expect(line(MetricDiagnostics.diskWrites(megabytes: 2048.4, version: "0.14.0"))
            == #"diagnostic disk-writes "written=2048MB version=0.14.0""#)
        #expect(line(MetricDiagnostics.hang(seconds: .nan, version: "not a version"))
            == #"diagnostic hang "duration=? version=?""#)
    }
}
