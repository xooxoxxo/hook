import Foundation
import Testing
@testable import RelayCore

/// Stable step ids: ticks keyed by id and content hash (TickStore v3), the id-based answer
/// rule (`answerRule` vectors), and the nodes that carry both.
private func revisionCases(_ kind: String) throws -> [JSONValue] {
    let url = try #require(Bundle.module.url(
        forResource: "revision-vectors", withExtension: "json", subdirectory: "Fixtures"))
    let root = try JSONValue.parse(Data(contentsOf: url))
    guard case .array(let cases)? = root["cases"] else { return [] }
    return cases.filter { $0["kind"]?.stringValue == kind }
}

private func steps(_ count: Int, detail: [Int: String] = [:]) -> [Step] {
    (1...count).map { Step(action: "Step \($0)", code: "run \($0)", detail: detail[$0], id: "s\($0)") }
}

private func nodes(_ steps: [Step]) -> [DetailModel.Node] {
    DetailModel.nodes(steps: steps, verify: nil)
}

@Suite struct StableIDTests {
    // MARK: Nodes

    @Test func aNodeCarriesItsStepIDAndVerifyIsVerify() {
        let built = DetailModel.nodes(steps: [Step(action: "A", id: "s1"),
                                              Step(action: "B", substeps: [Step(action: "B1", id: "s2.1")], id: "s2")],
                                      verify: Step(action: "Check"))
        #expect(built[0].stepID == "s1")
        #expect(built[1].stepID == "s2")
        #expect(built[1].children[0].stepID == "s2.1")
        #expect(built[2].stepID == "verify")
        #expect(built[0].contentHash.count == 16)
        #expect(DetailModel.nodes(steps: [Step(action: "A")], verify: nil)[0].stepID == nil)
    }

    @Test func theContentHashCoversEveryFieldButIDAndSubsteps() {
        let base = Step(action: "Run", code: "make", id: "s1")
        let hash = StepIdentity.contentHash(base, parentID: nil, kind: .step)
        var moved = base
        moved.id = "s9"
        moved.substeps = [Step(action: "x")]
        #expect(StepIdentity.contentHash(moved, parentID: nil, kind: .step) == hash)
        for change in [{ (s: inout Step) in s.detail = "more" }, { $0.expect = "ok" }, { $0.warning = "careful" },
                       { $0.code = "make all" }, { $0.url = "https://example.com" }, { $0.blocking = true }] {
            var other = base
            change(&other)
            #expect(StepIdentity.contentHash(other, parentID: nil, kind: .step) != hash)
        }
        #expect(StepIdentity.contentHash(base, parentID: "s2", kind: .sub) != hash)
    }

    /// Toggling `required` keeps ticks and answers (RD 12); an ask without the key hashes as in 0.12.
    @Test func requiredIsLeftOutOfTheContentHash() {
        let base = Step(action: "Rotate the key", code: "make rotate", id: "s2")
        let hash = StepIdentity.contentHash(base, parentID: nil, kind: .step)
        #expect(hash == "98448cd0d60ac522")
        for required in [true, false] {
            var marked = base
            marked.required = required
            #expect(StepIdentity.contentHash(marked, parentID: nil, kind: .step) == hash)
        }
    }

    // MARK: Ticks

    @Test func v2TicksMigrateToV3ByID() throws {
        try withDefaults { d in
            let tree = nodes(steps(3))
            d.set(["2": tree[1].fingerprint, "3": tree[2].fingerprint], forKey: TickStore.key(sourceKey: "local", id: "a"))
            let ticks = TickStore.load(d, sourceKey: "local", id: "a", nodes: tree)
            #expect(ticks == ["2", "3"])
            #expect(d.dictionary(forKey: TickStore.keyV3(sourceKey: "local", id: "a")) as? [String: String]
                == ["s2": tree[1].contentHash, "s3": tree[2].contentHash])
            #expect(d.object(forKey: TickStore.key(sourceKey: "local", id: "a")) == nil)
        }
    }

    @Test func aMovedStepKeepsItsTick() throws {
        try withDefaults { d in
            let before = nodes(steps(4))
            TickStore.save(d, sourceKey: "local", id: "a", ticks: ["3"], nodes: before)
            // Rev 2 moves s3 to position 4.
            var list = steps(4)
            list.swapAt(2, 3)
            #expect(TickStore.load(d, sourceKey: "local", id: "a", nodes: nodes(list)) == ["4"])
        }
    }

    @Test func aChangedStepLosesItsTick() throws {
        try withDefaults { d in
            TickStore.save(d, sourceKey: "local", id: "a", ticks: ["2", "3"], nodes: nodes(steps(3)))
            let changed = nodes(steps(3, detail: [3: "Now with a flag"]))
            #expect(TickStore.load(d, sourceKey: "local", id: "a", nodes: changed) == ["2"])
            #expect((d.dictionary(forKey: TickStore.keyV3(sourceKey: "local", id: "a")) as? [String: String])?.keys
                .sorted() == ["s2"])
        }
    }

    @Test func asksWithoutIDsKeepV2() throws {
        try withDefaults { d in
            let legacy = nodes([Step(action: "A"), Step(action: "B")])
            TickStore.save(d, sourceKey: "local", id: "a", ticks: ["2"], nodes: legacy)
            #expect(d.dictionary(forKey: TickStore.key(sourceKey: "local", id: "a")) as? [String: String]
                == ["2": legacy[1].fingerprint])
            #expect(d.object(forKey: TickStore.keyV3(sourceKey: "local", id: "a")) == nil)
            #expect(TickStore.load(d, sourceKey: "local", id: "a", nodes: legacy) == ["2"])
        }
    }

    @Test func pruneCoversBothPrefixes() throws {
        try withDefaults { d in
            TickStore.save(d, sourceKey: "local", id: "a", ticks: ["1"], nodes: nodes(steps(1)))
            TickStore.save(d, sourceKey: "local", id: "b", ticks: ["1"], nodes: nodes([Step(action: "A")]))
            TickStore.prune(d, sourceKey: "local", keep: [])
            #expect(d.object(forKey: TickStore.keyV3(sourceKey: "local", id: "a")) == nil)
            #expect(d.object(forKey: TickStore.key(sourceKey: "local", id: "b")) == nil)
        }
    }

    // MARK: Answers

    @Test func everyAnswerRuleVectorMatchesThePond() throws {
        let cases = try revisionCases("answerRule")
        #expect(cases.count >= 10)
        for item in cases {
            let name = item["name"]?.stringValue ?? ""
            guard case .array(let revisions)? = item["revisions"], case .int(let inForce)? = item["inForce"],
                  case .array(let rawEvents)? = item["events"] else {
                Issue.record("malformed \(name)")
                continue
            }
            var bodies: [Int: Instructable] = [:]
            for revision in revisions {
                guard case .int(let rev)? = revision["rev"], let body = revision["body"]?.stringValue else { continue }
                bodies[rev] = try RevisionBody.parse(body)
            }
            let events = rawEvents.map { e -> Event in
                var rev: Int?
                if case .int(let n)? = e["rev"] { rev = n }
                if case .int(let seq)? = e["seq"] {
                    return Event(seq: seq, itemId: "a", kind: e["kind"]?.stringValue ?? "", actor: e["actor"]?.stringValue ?? "",
                                 text: e["text"]?.stringValue, at: e["at"]?.stringValue ?? "", rev: rev)
                }
                return Event(seq: 0, itemId: "a", kind: "", actor: "", at: "")
            }
            let result = Answers.current(events: events, bodies: bodies, inForce: try #require(bodies[inForce]))
            #expect(encode(result.counted) == item["counted"], "\(name): counted")
            #expect(encode(result.earlier) == item["earlier"], "\(name): earlier")
        }
    }

    @Test func anEarlierAnswerShowsOnItsNodeAndDoesNotCount() throws {
        let one = Instructable(title: "T", steps: [Step(action: "Pick", question: Question(prompt: "Env?", choices: ["A", "B"]),
                                                        id: "s1")])
        var two = one
        two.steps[0].question?.choices = ["A", "C"]
        let event = Event(seq: 1, itemId: "a", kind: "answer", actor: "owner", text: "{\"step\":\"1\",\"picked\":[\"B\"]}",
                          at: "t", rev: 1)
        let history = VerifiedHistory(bodies: [1: one, 2: two], stamps: [:], current: RevisionStamp(rev: 2, hash: "h"),
                                      acceptedOnPond: 2, reasons: [:])
        let item = WireItem(id: "a", title: "T", status: "open", created: "", updated: "", payload: Payload(instructable: two))
        let model = DetailModel.make(item: item, events: [event], history: history)
        #expect(model.nodes[0].answer == nil)
        #expect(model.nodes[0].earlierAnswer?.picked == ["B"])
        #expect(model.unanswered == ["1"])
    }

    /// The vectors' shape: {id: {step, picked|text, id, at, seq, rev}}.
    private func encode(_ answers: [String: Answer]) -> JSONValue {
        .object(answers.mapValues { a in
            var fields: [String: JSONValue] = ["step": .string(a.step), "id": .string(a.id ?? ""), "at": .string(a.at),
                                               "seq": .int(a.seq), "rev": a.rev.map(JSONValue.int) ?? .null]
            if let picked = a.picked { fields["picked"] = .array(picked.map(JSONValue.string)) }
            if let text = a.text { fields["text"] = .string(text) }
            return .object(fields)
        })
    }
}
