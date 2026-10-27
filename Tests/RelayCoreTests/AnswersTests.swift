import Foundation
import Testing
@testable import RelayCore

/// Fixtures/answers-vectors.json: the mailbox reference's answer cases.
private func loadAnswerVectors() throws -> (instructable: JSONValue, cases: [JSONValue]) {
    let url = try #require(Bundle.module.url(
        forResource: "answers-vectors", withExtension: "json", subdirectory: "Fixtures"))
    let root = try JSONValue.parse(Data(contentsOf: url))
    let instructable = try #require(root["instructable"])
    guard root["version"] == .int(1), case .array(let cases)? = root["cases"] else {
        Issue.record("answers-vectors.json: version or cases")
        return (instructable, [])
    }
    return (instructable, cases)
}

private func strings(_ value: JSONValue?) -> [String] {
    guard case .array(let items)? = value else { return [] }
    return items.compactMap(\.stringValue)
}

private func event(_ seq: Int, _ text: String?, kind: String = "answer", actor: String = "owner") -> Event {
    Event(seq: seq, itemId: "a1", kind: kind, actor: actor, text: text, at: "2026-10-27T09:0\(seq % 10):00+00:00")
}

@Suite struct AnswersTests {
    @Test func everyVectorMatchesTheReference() throws {
        let (shared, cases) = try loadAnswerVectors()
        #expect(cases.count >= 46)
        for item in cases {
            let name = item["name"]?.stringValue ?? "?"
            let instructable: JSONValue? = {
                guard case .object(let members) = item, let own = members["instructable"] else { return shared }
                return own
            }()
            let expectedErrors = strings(item["errors"])
            let expectedEvents = strings(item["events"])
            switch Answers.validate(instructable, item["answers"] ?? .null) {
            case .success(let texts):
                #expect(item["valid"] == .bool(true), "\(name): Swift accepts what Python rejects")
                #expect(texts.count == expectedEvents.count, "\(name)")
                for (text, expected) in zip(texts, expectedEvents) {
                    #expect(try JSONValue.parse(Data(text.utf8)) == JSONValue.parse(Data(expected.utf8)), "\(name)")
                    #expect(text.hasPrefix("{\"step\":"), "\(name): step comes first")
                }
            case .failure(let failure):
                #expect(item["valid"] == .bool(false), "\(name): Swift rejects what Python accepts")
                #expect(failure.errors == expectedErrors, "\(name)")
            }
        }
    }

    @Test func questionsAreInDocumentOrder() throws {
        let (instructable, _) = try loadAnswerVectors()
        #expect(Answers.questions(instructable).map(\.path) == ["1", "2", "3", "4", "4.2"])
        #expect(Answers.questions(.null).isEmpty)
        let typed = try JSONDecoder().decode(Instructable.self, from: instructable.data())
        #expect(Answers.paths(typed) == ["1", "2", "3", "4", "4.2"])
    }

    @Test func entriesBuildWhatValidateTakes() throws {
        let (instructable, _) = try loadAnswerVectors()
        let batch: JSONValue = .array([Answers.entry(step: "2", picked: ["Traces", "Logs"]),
                                       Answers.entry(step: "3", text: "EU / west")])
        #expect(Answers.validate(instructable, batch)
            == .success([#"{"step":"2","picked":["Logs","Traces"]}"#, #"{"step":"3","text":"EU / west"}"#]))
    }

    @Test func latestAnswerWinsBySeq() {
        let events = [
            event(5, #"{"step":"1","picked":["Prod"]}"#),
            event(2, #"{"step":"1","picked":["Staging"]}"#),
            event(3, #"{"step":"3","text":"EU"}"#),
            event(4, #"{"step":"3","text":"US"}"#, actor: "session"),
            event(6, #"{"step":"2","picked":["Logs"]}"#, kind: "reply"),
            event(7, "not json"),
            event(8, nil),
            event(9, #"{"picked":["Prod"]}"#),
        ]
        let latest = Answers.latest(events)
        #expect(Set(latest.keys) == ["1", "3"])
        #expect(latest["1"] == Answer(step: "1", picked: ["Prod"], at: "2026-10-27T09:05:00+00:00", seq: 5))
        #expect(latest["3"]?.text == "EU")
        #expect(latest["3"]?.picked == nil)
    }

    @Test(arguments: [("1", true), ("20", true), ("3.2", true), ("99.99", true), ("0", false), ("01", false),
                      ("1.0", false), ("100", false), ("4.2.1", false), ("verify", false), ("", false), ("1.", false),
                      ("\u{0661}", false)])
    func paths(_ text: String, _ valid: Bool) {
        #expect(Answers.isPath(text) == valid)
    }
}
