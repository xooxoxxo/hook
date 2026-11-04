import Foundation
import Testing
@testable import RelayCore

private func fixture(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "ips", subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

/// A small fixed-seed generator, so a failure always reproduces.
private struct SplitMix: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Whatever a crash file holds, reading it and building the bar, the report and the issue
/// from it never traps: the launch check runs on every start, and a trap there loops.
@Suite struct IPSFuzzTests {
    private let header = #"{"app_name":"Hook","bug_type":"309","os_version":"macOS 27.0.1 (27A100)"}"# + "\n"

    /// Parse, then everything the offer path builds from the result.
    private func survives(_ data: Data) {
        let report = try? IPSReport.parse(data)
        let s = CrashSummary(report: report, hookVersion: "0.14.0", macOS: "27.0.1", cpu: "arm64", when: Date(),
                             run: Date())
        let body = CrashReportText.body(s, source: "Pond", pond: "1.4.0", log: ["launch hook=0.14.0"],
                                        home: "/Users/me", user: "me")
        _ = BugAsk.instructable(s, body: body)
        _ = BugAsk.title(s)
        _ = GitHubIssues.newIssueURL(title: BugAsk.title(s), body: GitHubIssues.issueBody(body, sameAs: 3))
        _ = s.handledKey
        #expect(s.signature.count == 12)
    }

    @Test func oddShapesDontTrap() {
        let bodies = [
            "", "{}", "[]", "null", "42", "\"x\"",
            #"{"exception":null}"#,
            #"{"exception":{"type":42}}"#,
            #"{"exception":{"type":""}}"#,
            #"{"exception":{"type":"EXC_CRASH","signal":7},"faultingThread":"0","threads":{}}"#,
            #"{"exception":{"type":"EXC_CRASH"},"faultingThread":-1,"threads":[{"frames":[1,"a",null,{}]}]}"#,
            #"{"exception":{"type":"EXC_CRASH"},"faultingThread":99999999999,"threads":[]}"#,
            #"{"exception":{"type":"EXC_CRASH"},"faultingThread":true,"threads":[{},{"triggered":true,"frames":"x"}]}"#,
            #"{"exception":{"type":"EXC_CRASH"},"threads":[{"triggered":true,"frames":[{"imageIndex":"0"},{"imageIndex":0,"imageOffset":1e300,"symbol":7}]}],"usedImages":[{"name":"Hook"}]}"#,
            #"{"exception":{"type":"EXC_CRASH"},"threads":[{"triggered":true,"frames":[{"imageIndex":0,"imageOffset":-9223372036854775808,"symbolLocation":-1}]}],"usedImages":[{"name":"Hook"}]}"#,
            #"{"exception":{"type":"EXC_CRASH"},"termination":{"namespace":7,"code":"x","indicator":[]},"usedImages":"Hook"}"#,
            #"{"exception":{"type":"EXC_CRASH"},"termination":"SIGNAL","usedImages":[null,7,{"name":null}]}"#,
            // macOS-27-shaped: the same fields under new wrappers, extra keys and types.
            #"{"crashReporterKey":"x","exception":{"type":"EXC_BAD_ACCESS","subtype":"KERN_INVALID_ADDRESS","codes":"0x1","signal":"SIGSEGV","ktriage":{"x":[1,2]}},"faultingThread":0,"threads":[{"id":1,"triggered":true,"frames":[{"imageIndex":0,"imageOffset":4096,"symbol":"SettingsWindow.open(tab:)","symbolLocation":212,"sourceLine":12,"inline":true}],"threadState":{"x":[{"value":1}]}}],"usedImages":[{"name":"Hook","arch":"arm64e","size":1},{"source":"P"}],"sharedCache":{"base":1},"vmSummary":"x","legacyInfo":{"threadTriggered":{"queue":"main"}},"trialInfo":{"rollouts":[]}}"#,
        ]
        for body in bodies {
            survives(Data((header + body).utf8))
            survives(Data(body.utf8))
        }
    }

    @Test func aHugeFrameListIsCutAndBounded() throws {
        let frame = #"{"imageIndex":0,"imageOffset":4096,"symbol":"\#(String(repeating: "S", count: 5000))","symbolLocation":1}"#
        let frames = Array(repeating: frame, count: 20_000).joined(separator: ",")
        let text = header + #"{"exception":{"type":"EXC_CRASH"},"faultingThread":0,"threads":[{"frames":["# + frames
            + #"]}],"usedImages":[{"name":"Hook"}]}"#
        let data = Data(text.utf8)
        #expect(data.count > IPSReport.maxBytes)
        #expect(throws: IPSReport.ParseError.self) { try IPSReport.parse(data) }
        let smaller = header + #"{"exception":{"type":"EXC_CRASH"},"faultingThread":0,"threads":[{"frames":["#
            + Array(repeating: frame, count: 1000).joined(separator: ",") + #"]}],"usedImages":[{"name":"Hook"}]}"#
        let report = try IPSReport.parse(Data(smaller.utf8))
        #expect(report.appFrames.count == IPSReport.frameLimit)
        #expect(report.appFrames.allSatisfy { ($0.symbol?.count ?? 0) <= 512 })
        survives(Data(smaller.utf8))
    }

    @Test func deepNestingIsRefusedWithoutRecursion() {
        let deep = header + String(repeating: "[", count: 200_000) + String(repeating: "]", count: 200_000)
        #expect(IPSReport.nestingDepth(Data(deep.utf8)) == 200_000)
        #expect(throws: IPSReport.ParseError.self) { try IPSReport.parse(Data(deep.utf8)) }
        // Brackets inside strings don't count, nor do escaped quotes end them.
        #expect(IPSReport.nestingDepth(Data(#"{"a":"[[[[\"[[[","b":[1]}"#.utf8)) == 2)
        survives(Data(deep.utf8))
    }

    @Test func mutatedReportsDontTrap() throws {
        var rng = SplitMix(state: 0x1405)
        for name in ["crash-symbolicated", "crash-unsymbolicated"] {
            let original = [UInt8](try fixture(name))
            for _ in 0..<300 {
                var bytes = original
                for _ in 0..<Int.random(in: 1...12, using: &rng) {
                    let i = Int.random(in: 0..<bytes.count, using: &rng)
                    switch Int.random(in: 0..<4, using: &rng) {
                    case 0: bytes[i] = UInt8.random(in: 0...255, using: &rng)
                    case 1: bytes.remove(at: i)
                    case 2: bytes.insert(UInt8(ascii: ["{", "[", "\"", ",", ":", "-", "9"].randomElement(using: &rng)!), at: i)
                    default: bytes = Array(bytes.prefix(i))
                    }
                    if bytes.isEmpty { break }
                }
                survives(Data(bytes))
            }
        }
    }

    @Test func readSkipsAFileTooBigToBeAReport() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "hook-ips-fuzz-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let big = dir.appending(path: "Hook-big.ips")
        try Data(count: IPSReport.maxBytes + 1).write(to: big)
        #expect(IPSReport.read(big) == nil)
        let good = dir.appending(path: "Hook-good.ips")
        try fixture("crash-symbolicated").write(to: good)
        #expect(IPSReport.read(good)?.exception == "EXC_BAD_ACCESS")
        #expect(IPSReport.read(dir.appending(path: "missing.ips")) == nil)
    }
}
