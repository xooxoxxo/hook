import Foundation
import Testing
@testable import RelayCore

/// Fixtures/choice-vectors.json: the Pond 1.4.0 choice cases, recorded from a running Pond
/// over loopback. Ids show as `{ask1}`, `{ask2}`, … and timestamps as `{time}`.
struct ChoiceVectors {
    let cases: [String: (request: JSONValue, status: Int, response: JSONValue)]

    static func load() throws -> ChoiceVectors {
        let url = try #require(Bundle.module.url(forResource: "choice-vectors", withExtension: "json",
                                                 subdirectory: "Fixtures"))
        let root = try JSONValue.parse(try Data(contentsOf: url))
        guard root["pond"] == .string("1.4.0"), case .array(let cases)? = root["cases"] else {
            throw QueueError.notSupported
        }
        var out: [String: (JSONValue, Int, JSONValue)] = [:]
        for entry in cases {
            guard let name = entry["name"]?.stringValue, let request = entry["request"],
                  case .int(let status)? = entry["response"]?["status"], let body = entry["response"]?["body"]
            else { continue }
            out[name] = (request, status, body)
        }
        return ChoiceVectors(cases: out)
    }

    /// The instructable a vector posts (`POST /asks`).
    func posted(_ name: String) throws -> JSONValue {
        try #require(cases[name]?.request["body"]?["instructable"])
    }
}

private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
    try JSONDecoder().decode(type, from: Data(json.utf8))
}

@Suite struct ChoiceTests {
    @Test func decodesStringAndObject() throws {
        let question = try decode(Question.self, #"""
        {"prompt":"How should it roll out?","choices":["All at once",{"label":"Mix","text":"What should change?"}]}
        """#)
        #expect(question.choices == [Choice("All at once"), Choice("Mix", text: "What should change?")])
        #expect(question.options == ["All at once", "Mix"])
        #expect(question.placeholder(at: 0) == nil)
        #expect(question.placeholder(at: 1) == "What should change?")
        #expect(question.placeholder(at: 7) == nil)
        let reply = try decode(ReplySpec.self, #"{"prompt":"Anything else?","choices":["No",{"label":"Yes","text":"What else?"}]}"#)
        #expect(reply.options == ["No", "Yes"])
        #expect(reply.placeholder(at: 1) == "What else?")
        #expect(reply.hasWords)
        #expect(!question.allowsMany)
    }

    @Test func encodesPlainAsString() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode([Choice("Yes"), Choice("Mix", text: "What should change?")])
        #expect(String(decoding: data, as: UTF8.self) == #"["Yes",{"label":"Mix","text":"What should change?"}]"#)
        // A string literal is a plain choice, so `choices: ["A", "B"]` reads as before.
        let literal: Choice = "Staff first"
        #expect(literal == Choice("Staff first") && literal.text == nil)
    }

    /// Lenient, as `Step.question` is: a malformed choice drops the question, never the instructable.
    @Test func malformedChoiceDropsQuestionNotInstructable() throws {
        let ins = try decode(Instructable.self, #"""
        {"v":1,"title":"Roll out","steps":[{"do":"Pick","question":{"prompt":"How?","choices":["A",7]}},
         {"do":"Pick again","question":{"prompt":"How?","choices":["A",{"text":"no label"}]}},
         {"do":"Still fine","question":{"prompt":"How?","choices":["A",{"label":"B","text":"Why?"}]}}]}
        """#)
        #expect(ins.steps.count == 3)
        #expect(ins.steps[0].question == nil)
        #expect(ins.steps[1].question == nil)
        #expect(ins.steps[2].question?.options == ["A", "B"])
    }

    /// Every served body of the vectors decodes, and the protocol 5 views hold labels only.
    @Test func everyServedAskDecodes() throws {
        let vectors = try ChoiceVectors.load()
        let detail6 = try #require(vectors.cases["choice-detail-protocol-6"]).response
        let item6 = try JSONDecoder().decode(AskDetail.self, from: detail6.data()).item
        let steps6 = try #require(item6.instructable?.steps)
        #expect(steps6[1].question?.choices?[1] == Choice("Mix", text: "What should change?"))
        #expect(item6.instructable?.reply?.placeholder(at: 1) == "What else?")
        #expect(item6.revision != nil)
        let body = try RevisionBody.parse(try #require(item6.revision?.body))
        #expect(body.steps[1].question?.placeholder(at: 1) == "What should change?")

        let detail5 = try #require(vectors.cases["choice-detail-protocol-5"]).response
        let item5 = try JSONDecoder().decode(AskDetail.self, from: detail5.data()).item
        #expect(item5.instructable?.steps[1].question?.choices?.allSatisfy { $0.text == nil } == true)
        #expect(item5.instructable?.steps[1].question?.options == ["All at once", "Mix", "Staff first"])
    }
}
