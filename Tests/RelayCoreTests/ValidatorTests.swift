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
                    if vector.name.hasPrefix("optional-") || vector.name.hasPrefix("file-") {
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
        #expect(Validator.leafKeys == Validator.verifyKeys.union(["question", "blocking", "warning", "optional", "file"]))
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
