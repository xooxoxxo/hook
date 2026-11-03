import Foundation
import Testing
@testable import RelayCore

private let when = Date(timeIntervalSince1970: 1_760_000_000)
private let report = IPSReport(exception: "EXC_BAD_ACCESS", signal: "SIGSEGV", termination: nil, appFrames: [
    .init(symbol: "SettingsWindow.open(tab:)", offset: 212, imageOffset: 0x41a2c),
    .init(symbol: "AppDelegate.showSettings(_:)", offset: 48, imageOffset: 0x1b3f0),
])
private let crash = CrashSummary(report: report, hookVersion: "0.12.0", macOS: "15.6.0", cpu: "arm64", when: when)

/// A log long enough to push the report past 4,000 characters.
private let longLog = (1...200).map {
    "2026-10-15T22:00:00Z error type=http status=503 route=asks/{id}/reply line=\($0) message=\""
        + String(repeating: "the Pond is busy ", count: 6) + "\""
}

private func body(_ log: [String]) -> String {
    CrashReportText.body(crash, source: "Pond", pond: "1.2.0", log: log, home: "/Users/me", user: "me")
}

private func decoded(_ data: Data) throws -> JSONValue { try JSONValue.parse(data) }

@Suite struct BugAskTests {
    @Test func theAskPassesTheValidator() throws {
        let data = BugAsk.instructable(crash, body: body(["2026-10-15T22:13:58Z launch hook=0.12.0 macos=15.6.0 cpu=arm64"]))
        let value = try decoded(data)
        guard case .success = Validator.validate(value) else {
            Issue.record("the bug ask must validate: \(Validator.validate(value))")
            return
        }
        guard case .object(let object) = value, case .array(let steps)? = object["steps"],
              case .object(let step)? = steps.first else {
            Issue.record("one step")
            return
        }
        #expect(object["title"] == .string(crash.title))
        #expect(object["urgency"] == .string("whenever"))
        #expect(steps.count == 1)
        #expect(step["do"] == .string(BugAsk.step))
        #expect(step["code"] == .string(body(["2026-10-15T22:13:58Z launch hook=0.12.0 macos=15.6.0 cpu=arm64"])))
        #expect(step["lang"] == .string("text"))
        #expect(BugAsk.project == "Hook")
    }

    /// The `do` has nothing to copy in it (the lint rule): no URL, path, host or command.
    @Test func theStepTextHasNoValueToCopy() {
        for text in [BugAsk.step, BugAsk.why] {
            #expect(!text.contains("/") && !text.contains("`") && !text.contains("=") && !text.contains(":"))
        }
    }

    @Test func aLongLogIsTrimmedOldestFirstToTheCodeLimit() throws {
        let full = body(longLog)
        #expect(full.unicodeScalars.count > BugAsk.codeLimit)
        let code = BugAsk.code(full)
        #expect(code.unicodeScalars.count <= BugAsk.codeLimit)
        #expect(code.hasPrefix(crash.title + "\n" + CrashReportText.signatureLine(crash.signature)))
        // The newest line survives, the oldest goes, and the header follows the count.
        #expect(code.hasSuffix(RollingLog.oneLine(longLog.last!)))
        #expect(full.contains("line=161 "))
        #expect(!code.contains("line=161 "))
        let kept = code.components(separatedBy: "\n").filter { $0.contains(" error type=http") }.count
        #expect(kept > 0 && kept < CrashReportText.logLines)
        #expect(code.contains("Last \(kept) log lines"))
        guard case .success = Validator.validate(try decoded(BugAsk.instructable(crash, body: full))) else {
            Issue.record("a trimmed bug ask must validate")
            return
        }
    }

    @Test func aLongTitleKeepsItsSignature() {
        let long = IPSReport(exception: "EXC_BAD_ACCESS", signal: nil, termination: nil,
                             appFrames: [.init(symbol: String(repeating: "VeryLongTypeName.", count: 10) + "run()",
                                               offset: 1, imageOffset: 1)])
        let s = CrashSummary(report: long, hookVersion: "0.12.0", macOS: "15.6.0", cpu: "arm64", when: when)
        #expect(s.title.count > 120)
        let title = BugAsk.title(s)
        #expect(title.count == 120)
        #expect(title.hasSuffix("… (\(s.signature))"))
        #expect(BugAsk.title(crash) == crash.title)
    }

    @Test func fitKeepsTheHeadAndCutsWhenNothingElseFits() {
        let text = "Title\nCrash signature: hook-crash-abc\n\nLast 3 log lines\na\nb\nc"
        let all = CrashReportText.fit(text) { _ in true }
        #expect(all.text == text && !all.trimmed)
        let two = CrashReportText.fit(text) { $0.count <= text.count - 2 }
        #expect(two.text == "Title\nCrash signature: hook-crash-abc\n\nLast 2 log lines\nb\nc")
        #expect(two.trimmed)
        let head = CrashReportText.fit(text) { $0.count <= 12 }
        #expect(head.text == "Title")
    }

    @Test func resultLines() {
        #expect(BugPostResult.filed(id: "a").text == "Sent to your Pond.")
        #expect(BugPostResult.occurrence(id: "a", count: 3).text == "Added to the existing report (3 times).")
        #expect(BugPostResult.occurrence(id: "a", count: nil).text == "Added to the existing report.")
    }
}
