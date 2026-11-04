import Foundation
import Testing
@testable import RelayCore

private func semver(_ text: String) -> PondVersion { .semver(SemVer(strict: text)!) }

/// Fixtures/limits-vectors.json: the Pond 1.4.0 caps, recorded from a running Pond over loopback.
private func limitsVector(_ name: String) throws -> (request: JSONValue, status: Int, response: JSONValue) {
    let url = try #require(Bundle.module.url(forResource: "limits-vectors", withExtension: "json", subdirectory: "Fixtures"))
    let root = try JSONValue.parse(try Data(contentsOf: url))
    guard root["pond"] == .string("1.4.0"), case .array(let cases)? = root["cases"],
          let entry = cases.first(where: { $0["name"] == .string(name) }),
          let request = entry["request"], case .int(let status)? = entry["response"]?["status"],
          let body = entry["response"]?["body"] else { throw QueueError.notSupported }
    return (request, status, body)
}

private func details(_ body: JSONValue) -> [String] {
    guard case .array(let items)? = body["details"] else { return [] }
    return items.compactMap(\.stringValue)
}

@Suite struct TalkLimitsTests {
    @Test func limits140() {
        for pond in ["1.4.0", "1.4.3", "1.9.0"] {
            #expect(TalkLimits.make(pond: semver(pond)) == TalkLimits(message: 8000, report: 8000, multilineReports: true),
                    "\(pond)")
        }
    }

    /// An older Pond, or one whose version check hasn't answered yet, keeps the 0.13 caps.
    @Test func limitsFallBackBelow140() {
        let old = TalkLimits(message: 1000, report: 300, multilineReports: false)
        #expect(TalkLimits.make(pond: semver("1.3.0")) == old)
        #expect(TalkLimits.make(pond: semver("1.4.0-rc.1")) == old)
        #expect(TalkLimits.make(pond: .legacy(protocol: 5)) == old)
        #expect(TalkLimits.make(pond: nil) == old)
        #expect(TalkLimits.old == old)
    }

    @Test func counterFrom80Percent() {
        #expect(!TalkLimits.showsCounter(6400, limit: 8000))
        #expect(TalkLimits.showsCounter(6401, limit: 8000))
        #expect(!TalkLimits.showsCounter(800, limit: 1000))
        #expect(TalkLimits.showsCounter(801, limit: 1000))
        #expect(!TalkLimits.showsCounter(240, limit: 300))
        #expect(TalkLimits.showsCounter(241, limit: 300))
        #expect(TalkLimits.showsCounter(9204, limit: 8000))
    }

    @Test func counterFormat() {
        #expect(TalkLimits.counter(7412, limit: 8000) == "7\u{202F}412 / 8\u{202F}000")
        #expect(TalkLimits.counter(801, limit: 1000) == "801 / 1\u{202F}000")
        #expect(TalkLimits.counter(12, limit: 300) == "12 / 300")
        #expect(TalkLimits.counter(1_234_567, limit: 8000) == "1\u{202F}234\u{202F}567 / 8\u{202F}000")
    }

    @Test func overText() {
        #expect(TalkLimits.over(9204, limit: 8000) == "Trim 1\u{202F}204 characters to send.")
        #expect(TalkLimits.over(8001, limit: 8000) == "Trim 1 character to send.")
        #expect(TalkLimits.over(301, limit: 300) == "Trim 1 character to send.")
    }

    @Test func overNilAtLimit() {
        #expect(TalkLimits.over(8000, limit: 8000) == nil)
        #expect(TalkLimits.over(0, limit: 8000) == nil)
    }

    /// The talk a source allows carries its caps.
    @Test func sessionTalkCarriesTheLimits() {
        let key = "mailbox:pond.example.com:8790#personal"
        #expect(SessionTalk.make(sourceKey: key, pond: semver("1.4.0")).limits.message == 8000)
        #expect(SessionTalk.make(sourceKey: key, pond: semver("1.3.0")).limits.message == 1000)
        #expect(SessionTalk.make(sourceKey: key, pond: nil).limits.report == 300)
        #expect(SessionTalk.make(sourceKey: "local:this-mac", pond: nil).limits == .old)
    }

    // MARK: Messages and reports against the caps

    @Test func messagesTakeTheLimitsCap() throws {
        let new = TalkLimits.make(pond: semver("1.4.0")), old = TalkLimits.old
        let at = try #require(limitsVector("limits-message-8000").request["body"]?["text"]?.stringValue)
        let over = try #require(limitsVector("limits-message-8001").request["body"]?["text"]?.stringValue)
        #expect(MessageText.canSend(at, limits: new))
        #expect(!MessageText.canSend(over, limits: new))
        #expect(!MessageText.canSend(at, limits: old))
        #expect(MessageText.canSend(String(repeating: "m", count: 1000), limits: old))
        #expect(!MessageText.canSend(" \n ", limits: new))
        let refused = try limitsVector("limits-message-8001")
        let error = QueueError.rejected(status: refused.status, error: "invalid message", details: details(refused.response))
        #expect(MessageText.refusal(error, limits: new) == "The Pond refused the message: it is over 8000 characters.")
        #expect(MessageText.refusal(error, limits: old) == "The Pond refused the message: it is over 1000 characters.")
    }

    /// On Pond 1.4.0 a note goes as typed, its ends trimmed, line breaks kept; before, as one line.
    @Test func reportsTakeTheLimitsCapAndKeepTheirLines() throws {
        let new = TalkLimits.make(pond: semver("1.4.0")), old = TalkLimits.old
        let traceback = try #require(limitsVector("limits-problem-multiline").request["body"]?["note"]?.stringValue)
        #expect(traceback.unicodeScalars.count == 937)
        let sent = ProblemReport.prepared("\n" + traceback + "  \n", limits: new)
        #expect(sent == traceback.trimmingCharacters(in: .whitespacesAndNewlines))
        #expect(sent.split(separator: "\n", omittingEmptySubsequences: false).count == 14)
        #expect(ProblemReport.canSend(traceback, limits: new))
        #expect(!ProblemReport.prepared(traceback, limits: old).contains("\n"))
        #expect(!ProblemReport.canSend(traceback, limits: old))
        let at = try #require(limitsVector("limits-problem-8000").request["body"]?["note"]?.stringValue)
        let over = try #require(limitsVector("limits-problem-8001").request["body"]?["note"]?.stringValue)
        #expect(ProblemReport.canSend(at, limits: new))
        #expect(!ProblemReport.canSend(over, limits: new))
        #expect(ProblemReport.count(over, limits: new) == 8001)
        #expect(ProblemReport.canSend(String(repeating: "x", count: 300), limits: old))
        #expect(!ProblemReport.canSend(String(repeating: "x", count: 301), limits: old))
        let refused = try limitsVector("limits-problem-8001")
        let error = QueueError.rejected(status: refused.status, error: "invalid problem", details: details(refused.response))
        #expect(ProblemReport.refusal(error, limits: new) == "The Pond refused the note: it is over 8000 characters.")
        let hidden = try limitsVector("limits-problem-hidden")
        let hiddenError = QueueError.rejected(status: 400, error: "invalid problem", details: details(hidden.response))
        #expect(ProblemReport.refusal(hiddenError, limits: new)
            == "The Pond refused the note: note: contains hidden or control characters (U+0007).")
    }
}
