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
