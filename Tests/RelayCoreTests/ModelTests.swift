import Foundation
import Testing
@testable import RelayCore

@Test func decodesFullInstructableItem() throws {
    let json = """
    {"id":"6f1c2b0e-8a1d-4c55-9a77-0d2f3c4b5a61","source":"mailbox","title":"Create a Slack channel",
     "status":"open","priority":1,"pinned":false,"rolling":false,"payloadType":"xo.ask","links":[],
     "created":"2026-10-10T12:00:00+00:00","updated":"2026-10-10T12:00:00+00:00","anchor":null,
     "recurrence":null,"snoozeUntil":null,"projectId":"Acme","lane":"work","completedAt":null,
     "payload":{"key":"k","why":null,"cmd":null,"link":null,"ext_id":1,"ext_ref":2,"note":null,
      "instructable":{"v":1,"title":"Create a Slack channel","why":"The brief needs a home","urgency":"now",
       "steps":[{"do":"Open Slack","where":"Slack"},
                {"do":"Check Node","code":"node --version","lang":"bash","expect":"v22","url":"https://nodejs.org"}],
       "verify":{"do":"Confirm","code":"ls"},
       "reply":{"prompt":"Which channel?","choices":["#a","#b"]},
       "links":[{"label":"Spec","url":"https://example.com"}],
       "from":{"session":"s1","host":"h","cwd":"/w"}}}}
    """
    let item = try JSONDecoder().decode(WireItem.self, from: Data(json.utf8))
    let ins = try #require(item.instructable)
    #expect(item.projectId == "Acme")
    #expect(item.urgency == "now")
    #expect(ins.steps.count == 2)
    #expect(ins.steps[0].place == "Slack")
    #expect(ins.steps[1].code == "node --version")
    #expect(ins.verify?.action == "Confirm")
    #expect(ins.reply?.choices == ["#a", "#b"])
    #expect(ins.links?.first?.label == "Spec")
}

@Test func legacyAskDecodesWithoutInstructable() throws {
    let json = """
    {"item":{"id":"0b8f3a52-1c2d-4e5f-8a9b-0c1d2e3f4a5b","source":"mailbox","title":"Rotate the key",
      "status":"open","projectId":"Acme","created":"2026-10-09T08:00:00+00:00",
      "updated":"2026-10-09T08:00:00+00:00",
      "payload":{"key":"k","why":"It expires Friday","cmd":"op item get x","link":"https://example.com/x",
                 "ext_id":1,"ext_ref":2,"note":null}},
     "events":[{"seq":1,"itemId":"0b8f3a52-1c2d-4e5f-8a9b-0c1d2e3f4a5b","kind":"posted","actor":"session","text":null,"at":"2026-10-09T08:00:00+00:00"},
               {"seq":2,"itemId":"0b8f3a52-1c2d-4e5f-8a9b-0c1d2e3f4a5b","kind":"steps","actor":"session","text":"1. Open the vault","at":"2026-10-09T08:01:00+00:00"}]}
    """
    let detail = try JSONDecoder().decode(AskDetail.self, from: Data(json.utf8))
    #expect(detail.item.instructable == nil)
    #expect(detail.item.urgency == "today")
    #expect(detail.item.payload.why == "It expires Friday")
    #expect(detail.item.payload.cmd == "op item get x")
    #expect(detail.item.payload.link == "https://example.com/x")
    #expect(detail.events.last?.kind == "steps")
    #expect(detail.events.last?.text == "1. Open the vault")
}

@Test func configFillsDefaultsAndHonoursEnv() throws {
    let json = #"{"mailboxURL":"http://127.0.0.1:8790","tokenFile":"/tmp/relay-test-token"}"#
    let config = try JSONDecoder().decode(RelayConfig.self, from: Data(json.utf8))
    #expect(config.port == 47823)
    #expect(config.pollSeconds == 15)
    #expect(RelayConfig.path(environment: ["RELAY_CONFIG": "/tmp/r.json"]).path == "/tmp/r.json")
}

private func decodeInstructable(_ json: String) throws -> Instructable {
    try JSONDecoder().decode(Instructable.self, from: Data(json.utf8))
}

@Test func substepsDecode() throws {
    let ins = try decodeInstructable("""
    {"v":1,"title":"Set up Slack","steps":[
      {"do":"Create the app","where":"api.example.com","substeps":[
        {"do":"Click Create New App","url":"https://api.example.com/apps"},
        {"do":"Name it Acme"},
        {"do":"Add the scope","code":"chat:write","lang":"text"}]},
      {"do":"Invite the bot"}]}
    """)
    #expect(ins.steps[0].substeps?.map(\.action) == ["Click Create New App", "Name it Acme", "Add the scope"])
    #expect(ins.steps[0].substeps?[0].url == "https://api.example.com/apps")
    #expect(ins.steps[0].substeps?[2].code == "chat:write")
    #expect(ins.steps[0].place == "api.example.com")
    #expect(ins.steps[1].substeps == nil)
}

@Test func nullSubstepsIsNil() throws {
    let ins = try decodeInstructable(#"{"v":1,"title":"T","steps":[{"do":"a","substeps":null}]}"#)
    #expect(ins.steps[0].substeps == nil)
    #expect(ins.steps[0].action == "a")
}

@Test func malformedSubstepsKeepTheInstructable() throws {
    let wrongType = try decodeInstructable(#"{"v":1,"title":"T","steps":[{"do":"a","where":"w","substeps":"x"}]}"#)
    #expect(wrongType.steps[0].substeps == nil)
    #expect(wrongType.steps[0].place == "w")
    let badItem = try decodeInstructable(#"{"v":1,"title":"T","steps":[{"do":"a","substeps":[{"where":"no do"}]}]}"#)
    #expect(badItem.steps[0].substeps == nil)
    #expect(badItem.steps[0].action == "a")
}

@Test func aStepWithoutDoStillFailsAsToday() {
    #expect(throws: DecodingError.self) {
        _ = try decodeInstructable(#"{"v":1,"title":"T","steps":[{"where":"w"}]}"#)
    }
}

@Test func substepsRoundTrip() throws {
    let step = Step(action: "Parent", substeps: [Step(action: "Child", code: "ls")])
    let data = try JSONEncoder().encode(step)
    #expect(try JSONDecoder().decode(Step.self, from: data) == step)
    #expect(String(decoding: data, as: UTF8.self).contains(#""substeps""#))
}

@Test func questionsDecodeOnStepsAndSubsteps() throws {
    let ins = try decodeInstructable("""
    {"v":1,"title":"Ship Atlas","steps":[
      {"do":"Pick the target","question":{"prompt":"Which environment?","choices":["Staging","Prod"]}},
      {"do":"Prepare","question":{"prompt":"Which signals?","choices":["Logs","Metrics"],"multi":true},
       "substeps":[{"do":"Tag it"},{"do":"Name the region","question":{"prompt":"Which region?"}}]},
      {"do":"No question","question":null}]}
    """)
    #expect(ins.steps[0].question == Question(prompt: "Which environment?", choices: ["Staging", "Prod"]))
    #expect(ins.steps[1].question?.allowsMany == true)
    #expect(ins.steps[1].substeps?[0].question == nil)
    #expect(ins.steps[1].substeps?[1].question?.isFreeText == true)
    #expect(ins.steps[2].question == nil)
}

@Test func malformedQuestionsKeepTheStep() throws {
    let ins = try decodeInstructable("""
    {"v":1,"title":"T","steps":[
      {"do":"a","question":"Which?"},
      {"do":"b","question":{"choices":["x"]}},
      {"do":"c","question":{"prompt":"P","choices":[1,2]}},
      {"do":"d","substeps":[{"do":"e","question":{"prompt":"P","multi":"yes"}}]}]}
    """)
    #expect(ins.steps.map(\.action) == ["a", "b", "c", "d"])
    #expect(ins.steps.allSatisfy { $0.question == nil })
    #expect(ins.steps[3].substeps?.first?.action == "e")
    #expect(ins.steps[3].substeps?.first?.question == nil)
}

@Test func blockingAndWarningDecodeLeniently() throws {
    let ins = try decodeInstructable("""
    {"v":1,"title":"T","steps":[
      {"do":"a","blocking":true,"warning":"Old key stops at once\\nCI fails"},
      {"do":"b","blocking":"yes","warning":5},
      {"do":"c","blocking":null,"warning":null,"substeps":[{"do":"d","blocking":false,"warning":"Shown once"}]}],
     "verify":{"do":"v","blocking":true}}
    """)
    #expect(ins.steps.map(\.action) == ["a", "b", "c"])
    #expect(ins.steps[0].blocking == true)
    #expect(ins.steps[0].warning == "Old key stops at once\nCI fails")
    #expect(ins.steps[1].blocking == nil && ins.steps[1].warning == nil)
    #expect(ins.steps[2].blocking == nil && ins.steps[2].warning == nil)
    #expect(ins.steps[2].substeps?.first?.blocking == false)
    #expect(ins.steps[2].substeps?.first?.warning == "Shown once")

    let nodes = DetailModel.nodes(steps: ins.steps, verify: ins.verify)
    #expect(nodes[0].isBlocking && nodes[0].warning == "Old key stops at once\nCI fails")
    #expect(!nodes[1].isBlocking && nodes[1].warning == nil)
    #expect(!nodes[2].children[0].isBlocking && nodes[2].children[0].content.warning == "Shown once")
    #expect(nodes[3].isVerify && !nodes[3].isBlocking)   // verify never blocks, whatever got past validation
}

@Test func blockingRoundTripsAndStaysOutWhenAbsent() throws {
    let step = Step(action: "a", blocking: true, warning: "w")
    #expect(try JSONDecoder().decode(Step.self, from: JSONEncoder().encode(step)) == step)
    let plain = String(decoding: try JSONEncoder().encode(Step(action: "a")), as: UTF8.self)
    #expect(!plain.contains("blocking") && !plain.contains("warning"))
}

@Test func questionsSurviveTheMailboxWireItem() throws {
    let json = """
    {"item":{"id":"a1","title":"Ship Atlas","status":"open","created":"2026-10-27T09:00:00+00:00",
      "updated":"2026-10-27T09:00:00+00:00","payload":{"instructable":{"v":1,"title":"Ship Atlas","steps":[
        {"do":"Pick","question":{"prompt":"Which environment?","choices":["Staging","Prod"],"multi":false}}]}}},
     "events":[{"seq":2,"itemId":"a1","kind":"answer","actor":"owner","text":"{\\"step\\":\\"1\\",\\"picked\\":[\\"Prod\\"]}",
                "at":"2026-10-27T09:01:00+00:00"}]}
    """
    let detail = try JSONDecoder().decode(AskDetail.self, from: Data(json.utf8))
    #expect(detail.item.instructable?.steps[0].question?.choices == ["Staging", "Prod"])
    #expect(detail.ownerEvents.map(\.kind) == ["answer"])
    let model = DetailModel.make(detail)
    #expect(model.nodes[0].question?.prompt == "Which environment?")
    #expect(model.nodes[0].answer?.picked == ["Prod"])
}

@Test func optionalDecodesLenientlyAndStaysOutWhenAbsent() throws {
    let ins = try decodeInstructable("""
    {"v":1,"title":"T","steps":[
      {"do":"a","optional":true},
      {"do":"b","optional":"yes"},
      {"do":"c","optional":null,"substeps":[{"do":"d","optional":true}]}]}
    """)
    #expect(ins.steps[0].optional == true)
    #expect(ins.steps[1].optional == nil)
    #expect(ins.steps[2].optional == nil)
    #expect(ins.steps[2].substeps?.first?.optional == true)
    let nodes = DetailModel.nodes(steps: ins.steps, verify: ins.verify)
    #expect(nodes[0].isOptional && !nodes[1].isOptional && !nodes[2].isOptional && nodes[2].children[0].isOptional)

    let step = Step(action: "a", optional: true)
    #expect(try JSONDecoder().decode(Step.self, from: JSONEncoder().encode(step)) == step)
    #expect(!String(decoding: try JSONEncoder().encode(Step(action: "a")), as: UTF8.self).contains("optional"))
}

@Test func fileAndLinkPathDecodeLeniently() throws {
    let ins = try decodeInstructable("""
    {"v":1,"title":"T","steps":[
      {"do":"a","file":"~/notes/plan.md"},
      {"do":"b","file":7},
      {"do":"c","file":"  ","substeps":[{"do":"d","file":"/tmp/x.md"}]}],
     "verify":{"do":"v","file":"/tmp/v.md"},
     "links":[{"label":"Spec","path":"/Users/me/spec.md"},{"label":"Web","url":"https://example.com"},
              {"label":"Odd","path":3}]}
    """)
    #expect(ins.steps[0].file == "~/notes/plan.md")
    #expect(ins.steps[1].file == nil)
    #expect(ins.steps[2].substeps?.first?.file == "/tmp/x.md")
    #expect(ins.links == [LinkRef(label: "Spec", path: "/Users/me/spec.md"), LinkRef(label: "Web", url: "https://example.com"),
                          LinkRef(label: "Odd", url: nil, path: nil)])
    #expect(ins.links?[0].file == "/Users/me/spec.md")
    #expect(ins.links?[1].file == nil)
    let nodes = DetailModel.nodes(steps: ins.steps, verify: ins.verify)
    #expect(nodes[0].file == "~/notes/plan.md")
    #expect(nodes[1].file == nil)
    #expect(nodes[2].file == nil)   // blank
    #expect(nodes[2].children[0].file == "/tmp/x.md")
    #expect(nodes[3].isVerify && nodes[3].file == nil)   // never on verify

    let step = Step(action: "a", file: "/tmp/a.md")
    #expect(try JSONDecoder().decode(Step.self, from: JSONEncoder().encode(step)) == step)
    #expect(try !String(decoding: JSONEncoder().encode(Step(action: "a")), as: UTF8.self).contains("file"))
    let link = LinkRef(label: "Spec", path: "/tmp/spec.md")
    #expect(try JSONDecoder().decode(LinkRef.self, from: JSONEncoder().encode(link)) == link)
    #expect(try !String(decoding: JSONEncoder().encode(link), as: UTF8.self).contains("url"))
}

@Test func optionalParentSubStepsCountInTheQueueRow() {
    let ins = Instructable(title: "Ask", steps: [
        Step(action: "a", substeps: [Step(action: "b", question: Question(prompt: "Feedback?"))], optional: true),
        Step(action: "c"),
    ])
    #expect(QueueLayout.optionalPaths(ins) == ["1", "1.1"])
}

@Test func optionalQuestionsLeaveTheUnansweredList() {
    let ins = Instructable(title: "Ask", steps: [
        Step(action: "a", question: Question(prompt: "Feedback?"), optional: true),
        Step(action: "b", question: Question(prompt: "Region?", choices: ["EU", "US"])),
        Step(action: "c"),
    ])
    let item = WireItem(id: "q", title: "Ask", status: "open", projectId: "Acme", created: "2026-10-27T09:00:00+00:00",
                        updated: "2026-10-27T09:00:00+00:00", payload: Payload(why: nil, cmd: nil, link: nil, instructable: ins))
    let detail = DetailModel.make(item: item, events: [])
    #expect(detail.unanswered == ["2"])
    #expect(detail.questionCount == 2)
    // The queue row counts a ticked optional question as done, and an answered one once.
    #expect(QueueLayout.summary(for: item, ticked: ["1"], answered: []) == .steps(done: 1, total: 3))
    #expect(QueueLayout.summary(for: item, ticked: ["1", "2"], answered: ["1"]) == .steps(done: 1, total: 3))
    #expect(QueueLayout.summary(for: item, ticked: ["3"], answered: ["2"]) == .steps(done: 2, total: 3))
}

// MARK: - Revisions, step ids and the owner (Pond 1.1.0)

private let revisedItemJSON = """
    {"id":"6f1c2b0e-8a1d-4c55-9a77-0d2f3c4b5a61","title":"Deploy","status":"open","projectId":"Acme",
     "created":"2026-10-29T10:00:00+00:00","updated":"2026-10-29T10:05:00+00:00",
     "payload":{"instructable":{"v":1,"title":"Deploy","steps":[{"do":"Build it","id":"s1"},
       {"do":"Check","id":"s2","substeps":[{"do":"Open","id":"s2.1"}]}]}},
     "revision":{"rev":2,"hash":"\(String(repeating: "b", count: 64))","prev":"\(String(repeating: "a", count: 64))",
       "at":"2026-10-29T10:05:00+00:00","reason":"Fix the build step",
       "body":"{\\"steps\\":[]}","acceptedRev":1}}
    """

@Test func aRevisedItemDecodesItsRevision() throws {
    let item = try JSONDecoder().decode(WireItem.self, from: Data(revisedItemJSON.utf8))
    let revision = try #require(item.revision)
    #expect(revision.rev == 2)
    #expect(revision.prev == String(repeating: "a", count: 64))
    #expect(revision.reason == "Fix the build step")
    #expect(revision.body == #"{"steps":[]}"#)
    #expect(revision.acceptedRev == 1)
    #expect(revision.stamp == RevisionStamp(rev: 2, hash: String(repeating: "b", count: 64)))
    #expect(item.instructable?.steps.map(\.id) == ["s1", "s2"])
    #expect(item.instructable?.steps[1].substeps?.first?.id == "s2.1")
}

@Test func anItemFromAnOlderPondHasNoRevision() throws {
    let json = """
        {"id":"x","title":"Deploy","status":"open","created":"2026-10-29T10:00:00+00:00",
         "updated":"2026-10-29T10:00:00+00:00","payload":{"instructable":{"title":"Deploy","steps":[{"do":"a"}]}}}
        """
    let item = try JSONDecoder().decode(WireItem.self, from: Data(json.utf8))
    #expect(item.revision == nil)
    #expect(item.instructable?.steps.first?.id == nil)
    // A malformed revision is dropped, not the ask.
    let odd = json.replacingOccurrences(of: #""payload""#, with: #""revision":{"rev":"2"},"payload""#)
    #expect(try JSONDecoder().decode(WireItem.self, from: Data(odd.utf8)).revision == nil)
}

@Test func aMalformedStepIdIsNil() throws {
    let ins = try JSONDecoder().decode(Instructable.self, from: Data(#"{"title":"t","steps":[{"do":"a","id":7}]}"#.utf8))
    #expect(ins.steps.first?.id == nil)
    #expect(ins.steps.first?.action == "a")
}

@Test func theDetailCarriesTheRevisionHistory() throws {
    let json = """
        {"item":\(revisedItemJSON),"events":[
          {"seq":1,"itemId":"x","kind":"answer","actor":"owner","text":"{}","at":"2026-10-29T10:06:00+00:00",
           "rev":2,"auth":"owner-key"},
          {"seq":2,"itemId":"x","kind":"problem","actor":"owner","text":"note","at":"2026-10-29T10:07:00+00:00"},
          {"seq":3,"itemId":"x","kind":"accepted","actor":"owner","text":null,"at":"2026-10-29T10:08:00+00:00",
           "rev":null,"auth":null}],
         "revisions":[{"rev":1,"hash":"\(String(repeating: "a", count: 64))","prev":"","at":"2026-10-29T10:00:00+00:00",
           "reason":"","body":"{}"}]}
        """
    let detail = try JSONDecoder().decode(AskDetail.self, from: Data(json.utf8))
    #expect(detail.revisions.map(\.rev) == [1])
    #expect(detail.revisions.first?.prev == "")
    #expect(detail.events[0].rev == 2)
    #expect(detail.events[0].auth == "owner-key")
    #expect(detail.events[1].rev == nil && detail.events[1].auth == nil)
    #expect(detail.ownerEvents.map(\.kind) == ["answer", "problem", "accepted"])
    let bare = #"{"item":\#(revisedItemJSON),"events":[]}"#
    #expect(try JSONDecoder().decode(AskDetail.self, from: Data(bare.utf8)).revisions == [])
}

@Test func ownerStatusDecodesWithAndWithoutSelf() throws {
    let json = """
        {"required":false,"keys":[{"id":"k1","label":"studio","status":"approved","created":"2026-10-29T10:00:00+00:00",
          "approvedAt":"2026-10-29T10:01:00+00:00"},
         {"id":"k2","label":"laptop","status":"pending","created":"2026-10-29T10:02:00+00:00","approvedAt":null}],
         "self":{"id":"k1","status":"approved"}}
        """
    let status = try JSONDecoder().decode(OwnerStatus.self, from: Data(json.utf8))
    #expect(!status.required)
    #expect(status.keys.map(\.status) == ["approved", "pending"])
    #expect(status.keys[1].approvedAt == nil)
    #expect(status.self_ == OwnerSelf(id: "k1", status: "approved"))
    let none = #"{"required":true,"keys":[],"self":null}"#
    #expect(try JSONDecoder().decode(OwnerStatus.self, from: Data(none.utf8)).self_ == nil)
    let absent = #"{"required":true,"keys":[]}"#
    #expect(try JSONDecoder().decode(OwnerStatus.self, from: Data(absent.utf8)).self_ == nil)
}

@Test func anEnrollmentDecodesBothReplies() throws {
    let created = #"{"id":"e1","code":"586039","expires":"2026-10-29T10:10:00+00:00","status":"pending"}"#
    #expect(try JSONDecoder().decode(Enrollment.self, from: Data(created.utf8))
        == Enrollment(id: "e1", code: "586039", status: "pending", expires: "2026-10-29T10:10:00+00:00"))
    let polled = #"{"id":"e1","status":"approved"}"#
    #expect(try JSONDecoder().decode(Enrollment.self, from: Data(polled.utf8))
        == Enrollment(id: "e1", code: nil, status: "approved", expires: nil))
}

// MARK: - doc (Pond 1.10.0)

private let planHash = "89e032b48f654c6a542172e4396fbb6bd1cd37cfa66a5a59e987d0a3f398a4fd"
private let listHash = "e139cee1c35bdf06b6041be67cab26f468b882c0fc9e32ec0684312d99906bab"

@Test func docDecodesOnStepsSubStepsAndLinks() throws {
    let ins = try decodeInstructable("""
    {"v":1,"title":"Review the release plan","steps":[
      {"do":"Read the plan","file":"~/notes/plan.md","doc":{"sha256":"\(planHash)","bytes":93}},
      {"do":"Go through it","substeps":[{"do":"Read the list","file":"/tmp/list.md","doc":{"bytes":26,"sha256":"\(listHash)"}}]}],
     "links":[{"label":"Checklist","path":"/tmp/list.md","doc":{"sha256":"\(listHash)","bytes":26}},
              {"label":"Site","url":"https://pond.example.test/plan"}]}
    """)
    #expect(ins.steps[0].doc == DocRef(sha256: planHash, bytes: 93))
    #expect(ins.steps[1].doc == nil)
    #expect(ins.steps[1].substeps?.first?.doc == DocRef(sha256: listHash, bytes: 26))
    #expect(ins.links?[0].doc == DocRef(sha256: listHash, bytes: 26))
    #expect(ins.links?[1].doc == nil)
}

/// Like the other step keys, a malformed `doc` is nil and never costs the step or the ask
/// (the validator refuses it; the Pond never serves one).
@Test func aMalformedDocKeepsTheStepAndTheAsk() throws {
    let ins = try decodeInstructable("""
    {"v":1,"title":"T","steps":[
      {"do":"a","file":"/tmp/a.md","doc":"\(planHash)"},
      {"do":"b","file":"/tmp/b.md","doc":{"sha256":"\(planHash)"}},
      {"do":"c","file":"/tmp/c.md","doc":{"sha256":"\(planHash)","bytes":"93"}},
      {"do":"d","file":"/tmp/d.md","doc":null}],
     "links":[{"label":"L","path":"/tmp/l.md","doc":[1,2]}]}
    """)
    #expect(ins.steps.map(\.action) == ["a", "b", "c", "d"])
    #expect(ins.steps.allSatisfy { $0.doc == nil })
    #expect(ins.steps.map(\.file) == ["/tmp/a.md", "/tmp/b.md", "/tmp/c.md", "/tmp/d.md"])
    #expect(ins.links?.first?.path == "/tmp/l.md" && ins.links?.first?.doc == nil)
}

@Test func docRoundTripsAndStaysOutWhenAbsent() throws {
    let doc = DocRef(sha256: planHash, bytes: 93)
    let step = Step(action: "Read the plan", file: "~/notes/plan.md", doc: doc)
    #expect(try JSONDecoder().decode(Step.self, from: JSONEncoder().encode(step)) == step)
    let link = LinkRef(label: "Plan", path: "~/notes/plan.md", doc: doc)
    #expect(try JSONDecoder().decode(LinkRef.self, from: JSONEncoder().encode(link)) == link)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    #expect(String(decoding: try encoder.encode(step), as: UTF8.self)
        == #"{"do":"Read the plan","doc":{"bytes":93,"sha256":"\#(planHash)"},"file":"~/notes/plan.md"}"#)
    #expect(!String(decoding: try JSONEncoder().encode(Step(action: "a", file: "/tmp/a.md")), as: UTF8.self).contains("doc"))
    #expect(!String(decoding: try JSONEncoder().encode(LinkRef(label: "L", path: "/tmp/l.md")), as: UTF8.self).contains("doc"))
}

/// The served payload keeps `doc` as it came, and a typed change to the instructable keeps it too.
@Test func docSurvivesThePayload() throws {
    let json = """
    {"instructable":{"v":1,"title":"Review the release plan","steps":[
      {"do":"Read the plan","file":"~/notes/plan.md","doc":{"sha256":"\(planHash)","bytes":93}}],
     "links":[{"label":"Checklist","path":"/tmp/list.md","doc":{"sha256":"\(listHash)","bytes":26}}]}}
    """
    var payload = try JSONDecoder().decode(Payload.self, from: Data(json.utf8))
    let served = try JSONValue.parse(Data(json.utf8))["instructable"]
    #expect(payload.instructableJSON == served)
    payload.instructable?.steps[0].action = "Read the release plan"
    let doc = payload.instructableJSON?["steps"].flatMap { value -> JSONValue? in
        if case .array(let steps) = value { return steps.first?["doc"] }
        return nil
    }
    #expect(doc == .object(["sha256": .string(planHash), "bytes": .int(93)]))
    let link = payload.instructableJSON?["links"].flatMap { value -> JSONValue? in
        if case .array(let links) = value { return links.first?["doc"] }
        return nil
    }
    #expect(link == .object(["sha256": .string(listHash), "bytes": .int(26)]))
}

/// A changed document is a changed step: its tick does not carry over.
@Test func aChangedDocChangesTheStepsContentHash() {
    let one = Step(action: "Read the plan", file: "~/notes/plan.md", doc: DocRef(sha256: planHash, bytes: 93), id: "s1")
    var two = one
    two.doc = DocRef(sha256: listHash, bytes: 93)
    var three = one
    three.doc = nil
    let hashes = [one, two, three].map { StepIdentity.contentHash($0, parentID: nil, kind: .step) }
    #expect(Set(hashes).count == 3)
    #expect(StepIdentity.contentHash(Step(action: "Read the plan", file: "~/notes/plan.md", id: "s1"), parentID: nil, kind: .step)
        == hashes[2])
}
