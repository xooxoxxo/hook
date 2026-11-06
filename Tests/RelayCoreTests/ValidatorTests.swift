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
    @Test func askWarningsRoundTripAndRespectTheTextLimit() throws {
        var input = minimal
        input["warning"] = .string(String(repeating: "w", count: 300))
        guard case .success(let cleaned) = Validator.validate(.object(input)) else {
            Issue.record("A valid ask warning was refused"); return
        }
        let data = try JSONEncoder().encode(cleaned)
        let ask = try JSONDecoder().decode(Instructable.self, from: data)
        #expect(ask.warning == String(repeating: "w", count: 300))
        #expect(try JSONDecoder().decode(Instructable.self, from: JSONEncoder().encode(ask)).warning == ask.warning)
        input["warning"] = .string(String(repeating: "w", count: 301))
        guard case .failure(let failure) = Validator.validate(.object(input)) else {
            Issue.record("An oversized warning was accepted"); return
        }
        #expect(failure.errors == ["warning: longer than 300 characters"])
    }

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
                    if ["optional-", "file-", "required-", "done-"].contains(where: vector.name.hasPrefix) {
                        #expect(failure.errors == vector.errors, "\(vector.name): the reference's order")
                    }
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

    @Test func optionalCasesAreInTheFixture() throws {
        let names = Set(try loadVectors().map(\.name))
        for name in ["optional-valid-true", "optional-valid-null", "optional-valid-on-substep", "optional-valid-with-question",
                     "optional-not-bool-string", "optional-substep-not-bool", "optional-on-verify", "optional-and-blocking",
                     "optional-and-blocking-substep", "optional-valid-false-blocking-true"] {
            #expect(names.contains(name), "\(name)")
        }
    }

    @Test func requiredAndDoneCasesAreInTheFixture() throws {
        let names = Set(try loadVectors().map(\.name))
        for name in ["required-valid-leaf", "required-valid-parent", "required-valid-substep", "required-valid-question",
                     "required-valid-with-blocking", "required-and-optional", "required-inside-optional-parent",
                     "required-on-verify", "required-not-bool-string", "required-parent-all-optional",
                     "required-valid-parent-all-optional-own-question"] {
            #expect(names.contains(name), "\(name)")
        }
        #expect(names.contains { $0.hasPrefix("done-") })
    }

    /// Without requirements (This Mac, RD 20) both keys are unknown and nothing else is checked.
    @Test func withoutRequirementsTheKeysAreUnknown() throws {
        let value = try JSONValue.parse(Data(#"""
        {"v":1,"title":"t","done":[],"steps":[{"do":"a","required":"yes","optional":true}]}
        """#.utf8))
        guard case .failure(let failure) = Validator.validate(value, requirements: false) else {
            Issue.record("should fail")
            return
        }
        #expect(failure.errors.sorted() == ["done: unknown key", "steps[0].required: unknown key"])
        guard case .failure(let full) = Validator.validate(value) else {
            Issue.record("should fail")
            return
        }
        #expect(full.errors == ["steps[0].required: must be true or false",
                                "done: must be a list of 1 to 3 of steps, reply, message"])
    }

    @Test func fileCasesAreInTheFixture() throws {
        let names = Set(try loadVectors().map(\.name))
        for name in ["file-valid-home", "file-valid-absolute", "file-valid-on-substep", "file-valid-500", "file-relative",
                     "file-tilde-user", "file-501", "file-multiline", "file-hidden-zwj", "file-on-verify",
                     "file-relative-after-bad-url", "file-link-path-valid", "file-link-path-and-url", "file-link-neither",
                     "file-link-path-relative", "optional-parent-blocking-substep",
                     "optional-parent-optional-blocking-substep", "optional-not-bool-long-warning",
                     "file-hidden-root-nofollow", "file-hidden-root-vol", "file-net-upper", "file-network-lower",
                     "file-net-double-slash", "file-net-private", "file-home-data-volume", "file-home",
                     "file-valid-hidden-inner", "file-valid-homebrew", "file-valid-networks-n1",
                     "file-link-path-hidden-root", "file-link-path-home"] {
            #expect(names.contains(name), "\(name)")
        }
    }

    @Test func fileAndOptionalParentErrorsAreTheMailboxStrings() {
        func errors(_ steps: [JSONValue], links: [JSONValue]? = nil) -> [String] {
            var input = minimal
            input["steps"] = .array(steps)
            if let links { input["links"] = .array(links) }
            guard case .failure(let failure) = Validator.validate(.object(input)) else { return [] }
            return failure.errors
        }
        #expect(errors([.object(["do": .string("a"), "file": .string("~/notes/plan.md")])]) == [])
        #expect(errors([.object(["do": .string("a"), "file": .string("notes/plan.md")])])
            == ["steps[0].file: must be an absolute path"])
        #expect(errors([.object(["do": .string("a"), "file": .string("/.vol/1/2")])])
            == ["steps[0].file: can't start with a hidden folder"])
        #expect(errors([.object(["do": .string("a"), "file": .string("/.nofollow/../a.md")])])
            == ["steps[0].file: must not contain . or .. segments"])
        for network in ["/NET/h/a.md", "/network/x/a.md", "//net/h/a.md", "/private/net/h/a.md",
                        "/System/Volumes/Data/home/u/a.md", "/home/u/a.md", "/private/var/automount/net/h",
                        "/var/automount/net/h", "/private/private/net/h", "/System/Volumes/Data/private/net/h",
                        "/System/Volumes/Data/private/var/automount/net/h"] {
            #expect(errors([.object(["do": .string("a"), "file": .string(network)])])
                == ["steps[0].file: can't be a network path"], "\(network)")
        }
        // N3: case folding turns these first folders into ASCII ones on disk.
        for folded in ["/\u{17F}ystem/Volumes/Data/home/u/a.md", "/Sy\u{FB06}em/Volumes/Data/net/h/a.md",
                       "/\u{212A}ext/a.md"] {
            #expect(errors([.object(["do": .string("a"), "file": .string(folded)])])
                == ["steps[0].file: the first folder name must be plain ASCII"], "\(folded)")
        }
        for fine in ["/Users/x/.config/a.md", "/homebrew/a.md", "/networks/a.md", "~/.config/a.md",
                     "/Users/Jos\u{E9}/a.md", "~/\u{DC}n\u{EF}code/a.md"] {
            #expect(errors([.object(["do": .string("a"), "file": .string(fine)])]) == [], "\(fine)")
        }
        #expect(errors([.object(["do": .string("a"), "optional": .bool(true),
                                 "substeps": .array([.object(["do": .string("b"), "blocking": .bool(true)])])])])
            == ["steps[0].substeps[0].blocking: can't be blocking inside an optional step"])
        #expect(errors([.object(["do": .string("a"), "optional": .string("yes"),
                                 "warning": .string(String(repeating: "w", count: 301))])])
            == ["steps[0].optional: must be true or false", "steps[0].warning: longer than 300 characters"])
        let step = JSONValue.object(["do": .string("a")])
        #expect(errors([step], links: [.object(["label": .string("Plan"), "path": .string("/tmp/plan.md")])]) == [])
        #expect(errors([step], links: [.object(["label": .string("Plan")])]) == ["links[0]: needs url or path, not both"])
        #expect(errors([step], links: [.object(["label": .string("Plan"), "path": .string("/tmp/plan.md"),
                                                "url": .string("https://example.com")])])
            == ["links[0]: needs url or path, not both"])
    }

    @Test func optionalErrorsAreTheMailboxStrings() {
        func errors(_ step: [String: JSONValue]) -> [String] {
            var input = minimal
            input["steps"] = .array([.object(step)])
            guard case .failure(let failure) = Validator.validate(.object(input)) else { return [] }
            return failure.errors
        }
        #expect(errors(["do": .string("a"), "optional": .string("yes")]) == ["steps[0].optional: must be true or false"])
        #expect(errors(["do": .string("a"), "optional": .bool(true), "blocking": .bool(true)])
            == ["steps[0].optional: can't be optional and blocking"])
        #expect(errors(["do": .string("a"), "optional": .bool(true), "blocking": .null]) == [])
    }

    @Test func stepAndLeafKeys() {
        #expect(Validator.verifyKeys == ["do", "where", "code", "lang", "expect", "detail", "url"])
        #expect(Validator.leafKeys == Validator.verifyKeys.union(["question", "blocking", "warning", "optional", "required",
                                                                  "file", "id"]))
        #expect(Validator.topKeys.contains("done"))
        #expect(!Validator.verifyKeys.contains("required"))
        #expect(!Validator.verifyKeys.contains("id"))
        #expect(Validator.linkKeys == ["label", "url", "path"])
        #expect(Validator.maxPath == 500)
        #expect(Validator.warningLimit == 300)
        #expect(Validator.questionKeys == ["prompt", "choices", "multi"])
        #expect(Validator.maxQuestions == 20)
        #expect(Validator.stepKeys == Validator.leafKeys.union(["substeps"]))
        #expect(Validator.maxSubsteps == 10)
        #expect(Validator.maxStepTotal == 60)
    }
}

/// Step ids (Pond 1.1.0), with the errors the Pond's `instructable.validate` gives for each
/// input: the same messages and order. The Pond's generated vectors don't carry an `id-`
/// family yet; these were computed from its validator.
@Suite struct ValidatorStepIdTests {
    static let cases: [(name: String, input: String, errors: [String])] = [
        ("id-valid-all", #"{"v":1,"title":"Deploy","steps":[{"do":"a","id":"s1"},{"do":"b","id":"build-2","substeps":[{"do":"c","id":"b.1"}]}]}"#,
         []),
        ("id-valid-digit-start", #"{"v":1,"title":"Deploy","steps":[{"do":"a","id":"1a"},{"do":"b","id":"1.2.3"}]}"#,
         []),
        ("id-valid-24", #"{"v":1,"title":"Deploy","steps":[{"do":"a","id":"aaaaaaaaaaaaaaaaaaaaaaaa"}]}"#,
         []),
        ("id-bad-upper", #"{"v":1,"title":"Deploy","steps":[{"do":"a","id":"S1x"}]}"#,
         ["steps[0].id: must match [a-z0-9][a-z0-9.-]{0,23}"]),
        ("id-bad-25", #"{"v":1,"title":"Deploy","steps":[{"do":"a","id":"aaaaaaaaaaaaaaaaaaaaaaaaa"}]}"#,
         ["steps[0].id: must match [a-z0-9][a-z0-9.-]{0,23}"]),
        ("id-bad-empty", #"{"v":1,"title":"Deploy","steps":[{"do":"a","id":""}]}"#,
         ["steps[0].id: must match [a-z0-9][a-z0-9.-]{0,23}"]),
        ("id-bad-hyphen-start", #"{"v":1,"title":"Deploy","steps":[{"do":"a","id":"-a"}]}"#,
         ["steps[0].id: must match [a-z0-9][a-z0-9.-]{0,23}"]),
        ("id-bad-hidden", #"{"v":1,"title":"Deploy","steps":[{"do":"a","id":"a\u202eb"}]}"#,
         ["steps[0].id: must match [a-z0-9][a-z0-9.-]{0,23}"]),
        ("id-bad-space", #"{"v":1,"title":"Deploy","steps":[{"do":"a","id":"a b"}]}"#,
         ["steps[0].id: must match [a-z0-9][a-z0-9.-]{0,23}"]),
        ("id-bad-unicode-digit", #"{"v":1,"title":"Deploy","steps":[{"do":"a","id":"a\u0661"}]}"#,
         ["steps[0].id: must match [a-z0-9][a-z0-9.-]{0,23}"]),
        ("id-step-number", #"{"v":1,"title":"Deploy","steps":[{"do":"a","id":"2"},{"do":"b","id":"3.1"}]}"#,
         ["steps[0].id: must not look like a step number", "steps[1].id: must not look like a step number"]),
        ("id-step-number-ok-like", #"{"v":1,"title":"Deploy","steps":[{"do":"a","id":"3.1.1"},{"do":"b","id":"3."}]}"#,
         []),
        ("id-duplicate", #"{"v":1,"title":"Deploy","steps":[{"do":"a","id":"s1"},{"do":"b","id":"s2","substeps":[{"do":"c","id":"s1"}]}]}"#,
         ["steps[1].substeps[0].id: duplicate"]),
        ("id-not-string", #"{"v":1,"title":"Deploy","steps":[{"do":"a","id":7},{"do":"b","id":true}]}"#,
         ["steps[0].id: must be a string", "steps[1].id: must be a string"]),
        ("id-partial", #"{"v":1,"title":"Deploy","steps":[{"do":"a","id":"s1"},{"do":"b"}]}"#,
         ["steps: ids must be given for every step or for none"]),
        ("id-partial-null", #"{"v":1,"title":"Deploy","steps":[{"do":"a","id":null},{"do":"b","id":"s2"}]}"#,
         ["steps: ids must be given for every step or for none"]),
        ("id-partial-substep", #"{"v":1,"title":"Deploy","steps":[{"do":"a","id":"s1","substeps":[{"do":"c"}]}]}"#,
         ["steps: ids must be given for every step or for none"]),
        ("id-none-at-all", #"{"v":1,"title":"Deploy","steps":[{"do":"a","substeps":[{"do":"c"}]}]}"#,
         []),
        ("id-verify-unknown", #"{"v":1,"title":"Deploy","steps":[{"do":"a","id":"s1"}],"verify":{"do":"v","id":"v1"}}"#,
         ["verify.id: unknown key"]),
        ("id-order", #"{"v":1,"title":"Deploy","steps":[{"id":"S"}],"verify":{"do":"v","id":"v"}}"#,
         ["steps[0].do: required", "steps[0].id: must match [a-z0-9][a-z0-9.-]{0,23}", "verify.id: unknown key"]),
        ("id-secret", #"{"v":1,"title":"Deploy","steps":[{"do":"a","id":"sk-ant-abc"}]}"#,
         ["steps[0].id: secret-like value"]),
        ("id-non-object-step", #"{"v":1,"title":"Deploy","steps":["x",{"do":"a","id":"s1"}]}"#,
         ["steps[0]: must be an object"]),
        ("id-bad-and-partial", #"{"v":1,"title":"Deploy","steps":[{"do":"a","id":"Bad"},{"do":"b"}]}"#,
         ["steps[0].id: must match [a-z0-9][a-z0-9.-]{0,23}", "steps: ids must be given for every step or for none"]),
    ]

    @Test func idsMatchThePond() throws {
        for (name, input, errors) in Self.cases {
            let value = try JSONValue.parse(Data(input.utf8))
            switch Validator.validate(value) {
            case .success: #expect(errors.isEmpty, "\(name) should fail with \(errors)")
            case .failure(let failure): #expect(failure.errors == errors, "\(name)")
            }
        }
    }

    @Test func anAcceptedIdIsKept() throws {
        let value = try JSONValue.parse(Data(#"{"v":1,"title":"t","steps":[{"do":"a","id":"s1"}]}"#.utf8))
        guard case .success(let clean) = Validator.validate(value) else {
            Issue.record("should pass")
            return
        }
        #expect(clean["steps"] == .array([.object(["do": .string("a"), "id": .string("s1")])]))
    }
}

/// Choice objects (Pond 1.4.0), held to Fixtures/choice-vectors.json.
@Suite struct ValidatorChoiceTests {
    @Test func choiceVectors() throws {
        let vectors = try ChoiceVectors.load()
        var checked = 0
        for (name, vector) in vectors.cases where vector.request["path"] == .string("/asks")
            && vector.request["method"] == .string("POST") {
            let instructable = try #require(vector.request["body"]?["instructable"], "\(name)")
            switch Validator.validate(instructable) {
            case .success:
                #expect(vector.status == 201, "\(name) passed, the Pond answered \(vector.status)")
            case .failure(let failure):
                let details = vector.response["details"].map { value -> [String] in
                    guard case .array(let items) = value else { return [] }
                    return items.compactMap(\.stringValue)
                } ?? []
                #expect(vector.status == 400 && failure.errors == details, "\(name): \(failure.errors)")
            }
            checked += 1
        }
        #expect(checked >= 13)
    }

    /// The mirror of the Pond's `_choice` where the vectors are silent.
    static let cases: [(String, String, [String])] = [
        ("choice-empty-label", #"{"v":1,"title":"t","steps":[{"do":"a","question":{"prompt":"p","choices":["A",{"label":" ","text":"w"}]}}]}"#,
         ["steps[0].question.choices[1].label: must not be empty"]),
        ("choice-label-lines", #"{"v":1,"title":"t","steps":[{"do":"a","question":{"prompt":"p","choices":["A",{"label":"B\nC","text":"w"}]}}]}"#,
         ["steps[0].question.choices[1].label: must be a single line"]),
        ("choice-text-number", #"{"v":1,"title":"t","steps":[{"do":"a","question":{"prompt":"p","choices":["A",{"label":"B","text":3}]}}]}"#,
         ["steps[0].question.choices[1].text: must be a string"]),
        ("choice-duplicate-across", #"{"v":1,"title":"t","steps":[{"do":"a","question":{"prompt":"p","choices":[{"label":"A","text":"w"},"A"]}}]}"#,
         ["steps[0].question.choices[1]: duplicate choice"]),
        ("choice-null", #"{"v":1,"title":"t","steps":[{"do":"a","question":{"prompt":"p","choices":["A",null]}}]}"#,
         ["steps[0].question.choices[1]: required"]),
        // A reply list of plain strings keeps the 1.3.0 rules: no duplicate check.
        ("reply-plain-duplicates", #"{"v":1,"title":"t","steps":[{"do":"a"}],"reply":{"prompt":"p","choices":["A","A"]}}"#, []),
        ("reply-object-duplicates", #"{"v":1,"title":"t","steps":[{"do":"a"}],"reply":{"prompt":"p","choices":["A",{"label":"A","text":"w"}]}}"#,
         ["reply.choices[1]: duplicate choice"]),
        ("reply-object-in-sub-step", #"{"v":1,"title":"t","steps":[{"do":"a","substeps":[{"do":"b","question":{"prompt":"p","multi":true,"choices":["A",{"label":"B","text":"w"}]}}]}]}"#,
         ["steps[0].substeps[0].question.choices[1]: a choice with text can't be in a multi question"]),
    ]

    @Test func choiceRulesMatchThePond() throws {
        for (name, input, errors) in Self.cases {
            let value = try JSONValue.parse(Data(input.utf8))
            switch Validator.validate(value) {
            case .success: #expect(errors.isEmpty, "\(name) should fail with \(errors)")
            case .failure(let failure): #expect(failure.errors == errors, "\(name)")
            }
        }
    }

    /// This Mac takes no choice objects in 0.14: an object reads as Pond 1.3.0 reads it.
    @Test func thisMacRefusesChoiceObjects() throws {
        let instructable = try ChoiceVectors.load().posted("choice-post")
        guard case .failure(let failure) = Validator.validate(instructable, choiceObjects: false) else {
            Issue.record("choiceObjects: false took an object")
            return
        }
        #expect(failure.errors == ["steps[1].question.choices[1]: must be a string", "reply.choices[1]: must be a string"])
        let plain = try ChoiceVectors.load().posted("choice-plain-post")
        if case .failure(let failure) = Validator.validate(plain, choiceObjects: false) {
            Issue.record("a plain ask failed: \(failure.errors)")
        }
    }
}
