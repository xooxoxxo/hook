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
