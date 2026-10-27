import Foundation
import Testing
@testable import RelayCore

/// One case of Fixtures/instructable-vectors.json, the validator's source of truth.
private struct Vector {
    let name: String
    let kind: String
    let input: JSONValue
    let valid: Bool
    let errors: [String]
    let cleaned: JSONValue?
    let pyBytes: Int?
}

private struct MalformedFixture: Error {
    let detail: String
}

private func loadVectors() throws -> [Vector] {
    let url = try #require(Bundle.module.url(
        forResource: "instructable-vectors", withExtension: "json", subdirectory: "Fixtures"))
    let root = try JSONValue.parse(Data(contentsOf: url))
    guard root["version"] == .int(1), case .array(let cases)? = root["cases"] else {
        throw MalformedFixture(detail: "version or cases")
    }
    return try cases.map { item in
        guard let name = item["name"]?.stringValue,
              let kind = item["kind"]?.stringValue,
              let input = item["input"],
              case .bool(let valid)? = item["valid"],
              case .array(let errors)? = item["errors"] else {
            throw MalformedFixture(detail: item["name"]?.stringValue ?? "a case without a name")
        }
        var pyBytes: Int?
        if case .int(let count)? = item["pyBytes"] { pyBytes = count }
        let cleaned = item["cleaned"] == .null ? nil : item["cleaned"]
        return Vector(
            name: name, kind: kind, input: input, valid: valid,
            errors: errors.compactMap(\.stringValue), cleaned: cleaned, pyBytes: pyBytes)
    }
}

private let minimal: [String: JSONValue] = [
    "v": .int(1), "title": .string("Create the Slack channel"),
    "steps": .array([.object(["do": .string("Open Slack")])]),
]

@Suite struct ValidatorTests {
    @Test func theFixtureIsThere() throws {
        let vectors = try loadVectors()
        #expect(vectors.count >= 200)
        #expect(Set(vectors.map(\.name)).count == vectors.count)
        #expect(vectors.contains { $0.kind == "project" })
        #expect(vectors.contains { $0.valid } && vectors.contains { !$0.valid })
    }

    @Test func everyVectorMatchesTheReference() throws {
        for vector in try loadVectors() {
            if vector.kind == "project" {
                let errors = Validator.validateProject(vector.input)
                #expect(errors.sorted() == vector.errors.sorted(), "\(vector.name)")
                #expect(errors.isEmpty == vector.valid, "\(vector.name)")
            } else {
                switch Validator.validate(vector.input) {
                case .success(let cleaned):
                    #expect(vector.valid, "\(vector.name): Swift accepts what Python rejects")
                    #expect(cleaned == vector.cleaned, "\(vector.name)")
                case .failure(let failure):
                    #expect(!vector.valid, "\(vector.name): Swift rejects what Python accepts")
                    #expect(failure.errors.sorted() == vector.errors.sorted(), "\(vector.name)")
                }
            }
            if let pyBytes = vector.pyBytes {
                #expect(PySize.bytes(vector.input) == pyBytes, "\(vector.name)")
            }
        }
    }

    @Test func cleanedOutputDefaultsTheUrgencyOnly() {
        #expect(Validator.validate(.object(minimal)) == .success(.object(minimal.merging(["urgency": .string("today")]) { $1 })))
        var now = minimal
        now["urgency"] = .string("now")
        #expect(Validator.validate(.object(now)) == .success(.object(now)))
        var null = minimal
        null["urgency"] = .null
        null["verify"] = .null
        #expect(Validator.validate(.object(null)) == .success(.object(null.merging(["urgency": .string("today")]) { $1 })))
    }

    @Test func errorsNameThePathNotTheValue() {
        var input = minimal
        input["why"] = .string("token ghp_example")
        guard case .failure(let failure) = Validator.validate(.object(input)) else {
            Issue.record("expected a failure")
            return
        }
        #expect(failure.errors == ["why: secret-like value"])
        #expect(!failure.errors.joined().contains("ghp_example"))
    }

    @Test func projectRules() {
        #expect(Validator.validateProject(.string("Acme")) == [])
        #expect(Validator.validateProject(nil) == ["project: required"])
        #expect(Validator.validateProject(.null) == ["project: required"])
        #expect(Validator.validateProject(.string("ghp_example")) == ["project: secret-like value"])
    }

    @Test func noteRules() {
        #expect(Validator.validateNote(nil) == [])
        #expect(Validator.validateNote(.null) == [])
        #expect(Validator.validateNote(.string("")) == [])
        #expect(Validator.validateNote(.string("line one\nline two")) == [])
        #expect(Validator.validateNote(.string(String(repeating: "n", count: 300))) == [])
        #expect(Validator.validateNote(.string(String(repeating: "n", count: 301))) == ["note: longer than 300 characters"])
        #expect(Validator.validateNote(.string("use sk-ant-example")) == ["note: secret-like value"])
        #expect(Validator.validateNote(.string("a\u{202E}b")) == ["note: contains hidden or control characters (U+202E)"])
        #expect(Validator.validateNote(.int(5)) == ["note: must be a string"])
    }

    @Test(arguments: [
        ("sk-ant-example", true), ("sk-exampleexampleexample", true), ("-sk-exampleexampleexample", true),
        ("ask-exampleexampleexample", false), ("_sk-exampleexampleexample", false), ("sk-example", false),
        ("xoxb-example", true), ("xoxc-example", false), ("ghp_example", true), ("github_pat_example", true),
        ("-----BEGIN OPENSSH PRIVATE KEY-----", true), ("-----BEGIN PUBLIC KEY-----", false),
        ("AKIAEXAMPLEEXAMPLE12", true), ("AKIAEXAMPLE", false),
        ("gh\u{200D}p_example", true), ("\u{FF47}\u{FF48}\u{FF50}\u{FF3F}example", true), ("Acme", false),
    ])
    func looksSecret(_ text: String, _ expected: Bool) {
        #expect(Validator.looksSecret(text) == expected)
    }

    @Test func substepCasesAreInTheFixture() throws {
        let names = Set(try loadVectors().map(\.name))
        for name in ["substeps-valid-three", "substeps-empty", "substeps-eleven", "substeps-null", "substeps-nested",
                     "substeps-on-verify", "substeps-unknown-key", "substeps-newline-do", "substeps-total-60",
                     "substeps-total-61", "substeps-secret-code"] {
            #expect(names.contains(name), "\(name)")
        }
    }

    @Test func questionCasesAreInTheFixture() throws {
        let names = Set(try loadVectors().map(\.name))
        for name in ["questions-valid-pick", "questions-valid-multi", "questions-valid-free-text",
                     "questions-valid-on-substep", "questions-valid-parent-and-substep", "questions-valid-twenty",
                     "questions-valid-null", "questions-unknown-key", "questions-choice-duplicate",
                     "questions-multi-one-choice", "questions-multi-free-text", "questions-on-verify",
                     "questions-twenty-one"] {
            #expect(names.contains(name), "\(name)")
        }
    }

    @Test func blockingCasesAreInTheFixture() throws {
        let names = Set(try loadVectors().map(\.name))
        for name in ["blocking-valid-true", "blocking-valid-null", "blocking-valid-on-substep", "blocking-not-bool-string",
                     "blocking-not-bool-number", "blocking-substep-not-bool", "blocking-on-verify", "warning-valid-multiline",
                     "warning-valid-300", "warning-301", "warning-hidden", "warning-secret", "warning-on-verify",
                     "warning-substep-too-long", "blocking-and-warning-both-bad"] {
            #expect(names.contains(name), "\(name)")
        }
    }

    @Test func stepAndLeafKeys() {
        #expect(Validator.verifyKeys == ["do", "where", "code", "lang", "expect", "detail", "url"])
        #expect(Validator.leafKeys == Validator.verifyKeys.union(["question", "blocking", "warning"]))
        #expect(Validator.warningLimit == 300)
        #expect(Validator.questionKeys == ["prompt", "choices", "multi"])
        #expect(Validator.maxQuestions == 20)
        #expect(Validator.stepKeys == Validator.leafKeys.union(["substeps"]))
        #expect(Validator.maxSubsteps == 10)
        #expect(Validator.maxStepTotal == 60)
    }
}
