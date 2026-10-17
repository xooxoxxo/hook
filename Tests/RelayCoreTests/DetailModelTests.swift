import Foundation
import Testing
@testable import RelayCore

private let askID = "6f1c2b0e-8a1d-4c55-9a77-0d2f3c4b5a61"
private let posted = "2026-10-11T09:30:00+00:00"
private let firstClose = "2026-10-11T10:05:00+00:00"
private let secondClose = "2026-10-11T10:20:00+00:00"

private func ask(_ payload: Payload, status: String = "open", projectId: String? = "Acme") -> WireItem {
    WireItem(
        id: askID, title: payload.instructable?.title ?? "Rotate the example key", status: status,
        projectId: projectId, created: posted, updated: posted, payload: payload)
}

private func event(_ seq: Int, _ kind: String, _ actor: String, _ text: String? = nil, at: String = posted) -> Event {
    Event(seq: seq, itemId: askID, kind: kind, actor: actor, text: text, at: at)
}

private func minimal(from: Origin? = nil) -> Payload {
    let ins = Instructable(v: 1, title: "Rotate the example key", steps: [Step(action: "Open the key page")], from: from)
    return Payload(why: nil, cmd: nil, link: nil, instructable: ins)
}

@Suite struct DetailModelTests {
    @Test func instructableWithStepsVerifyLinksReplyAndFrom() {
        let ins = Instructable(
            v: 1, title: "Rotate the example key", why: "The old key expires on Friday.\nIt is used by the job.",
            urgency: "now",
            steps: [
                Step(action: "Open the key page", place: "Browser", url: "https://example.com/keys"),
                Step(action: "Store the new key", place: "Terminal", code: "echo stored", lang: "bash",
                     expect: "stored", detail: "Use the key from the vault.\nNot the old one."),
            ],
            verify: Step(action: "The job log shows success", code: "tail -n 5 job.log"),
            reply: ReplySpec(prompt: "Which region?", choices: ["eu", "us"]),
            links: [LinkRef(label: "Runbook", url: "https://example.com/runbook")],
            from: Origin(session: "5f633ed3-a328-412b", host: "build-mac", cwd: "/work/acme"))
        let detail = AskDetail(
            item: ask(Payload(why: nil, cmd: nil, link: nil, instructable: ins)),
            events: [
                event(1, "posted", "session"),
                event(2, "reply", "owner", "choice: eu"),
                event(3, "reply", "session", "not the owner"),
            ])

        let model = DetailModel.make(detail)

        #expect(model.id == askID)
        #expect(model.title == "Rotate the example key")
        #expect(model.why == "The old key expires on Friday.\nIt is used by the job.")
        #expect(model.notes.isEmpty)
        #expect(model.origin?.summary == "acme · build-mac · 5f633ed3")
        #expect(model.origin?.resumeCommand == "cd '/work/acme' && claude --resume 5f633ed3-a328-412b")
        #expect(model.project == "Acme")
        #expect(model.urgency == "now")
        #expect(model.nodes.map(\.path) == ["1", "2", "verify"])
        #expect(model.nodes.map(\.label) == ["1", "2", "Verify"])
        #expect(model.nodes.map(\.kind) == [.step, .step, .verify])
        #expect(model.nodes.map(\.number) == [1, 2, 3])
        #expect(model.nodes[0].content == StepContent(action: "Open the key page", place: "Browser", url: "https://example.com/keys"))
        #expect(model.nodes[1].content == StepContent(action: "Store the new key", place: "Terminal",
                                                      detail: "Use the key from the vault.\nNot the old one.",
                                                      code: "echo stored", lang: "bash", expect: "stored"))
        #expect(model.nodes[2].content == StepContent(action: "The job log shows success", code: "tail -n 5 job.log"))
        #expect(model.stepTotal == 3)
        #expect(model.links == [LinkRef(label: "Runbook", url: "https://example.com/runbook")])
        #expect(model.reply == ReplySpec(prompt: "Which region?", choices: ["eu", "us"]))
        #expect(model.ownerReplies == ["choice: eu"])
        #expect(model.isOpen)
        #expect(model.closedBy == nil)
        #expect(model.closedAt == nil)
        #expect(DetailModel.make(item: detail.item, events: detail.events) == model)
    }

    @Test func originKeepsOnlyPresentParts() {
        let hostAndSession = DetailModel.make(AskDetail(
            item: ask(minimal(from: Origin(session: "abcdef12-3456", host: "build-mac", cwd: "  "))), events: []))
        #expect(hostAndSession.origin?.summary == "build-mac · abcdef12")
        #expect(hostAndSession.origin?.resumeCommand == nil)
        let cwdOnly = DetailModel.make(AskDetail(item: ask(minimal(from: Origin(cwd: "/work/acme"))), events: []))
        #expect(cwdOnly.origin?.summary == "acme")
        let none = DetailModel.make(AskDetail(item: ask(minimal(from: Origin())), events: []))
        #expect(none.origin == nil)
        #expect(DetailModel.make(AskDetail(item: ask(minimal()), events: [])).origin == nil)
    }

    /// Review Focus 1: a legacy mailbox ask with only why, cmd and link (no instructable).
    @Test func legacyCmdAndLinkAsk() {
        let payload = Payload(why: "It expires Friday", cmd: "relay --version", link: "https://example.com/x",
                              instructable: nil)
        let detail = AskDetail(
            item: ask(payload),
            events: [event(1, "posted", "session"), event(2, "steps", "session", "Then restart the job")])

        let model = DetailModel.make(detail)

        #expect(model.title == "Rotate the example key")
        #expect(model.why == "It expires Friday")
        #expect(model.urgency == "today")
        #expect(model.nodes.map(\.path) == ["1"])
        #expect(model.nodes.first?.content == StepContent(action: "Run this", code: "relay --version"))
        #expect(model.nodes.first?.fingerprint == StepFingerprint.make(kind: .step, action: "Run this", place: nil, code: "relay --version"))
        #expect(model.links == [LinkRef(label: "Link", url: "https://example.com/x")])
        #expect(model.notes == ["Then restart the job"])
        #expect(model.reply == nil)
        #expect(model.origin == nil)
        #expect(model.isOpen)
    }

    @Test func legacyWithoutCmdOrLink() {
        let payload = Payload(why: " ", cmd: "  \n", link: nil, instructable: nil)
        let model = DetailModel.make(AskDetail(item: ask(payload, projectId: nil), events: []))
        #expect(model.why == nil)
        #expect(model.nodes.isEmpty)
        #expect(model.links.isEmpty)
        #expect(model.project == "")
    }

    @Test func closedBySession() {
        let detail = AskDetail(
            item: ask(minimal(), status: "done"),
            events: [
                event(1, "posted", "session"),
                event(2, "reply", "owner", "On it"),
                event(3, "resolved", "session", at: firstClose),
            ])
        let model = DetailModel.make(detail)
        #expect(!model.isOpen)
        #expect(model.closedBy == "session")
        #expect(model.closedAt == firstClose)
        #expect(model.ownerReplies == ["On it"])
    }

    @Test func reopenedAskIsNeverShownAsClosed() {
        let reopened = AskDetail(
            item: ask(minimal(), status: "open"),
            events: [
                event(1, "posted", "session"),
                event(2, "resolved", "owner", at: firstClose),
                event(3, "reopened", "owner", at: secondClose),
            ])
        let model = DetailModel.make(reopened)
        #expect(model.isOpen)
        #expect(model.closedBy == nil)
        #expect(model.closedAt == nil)
        #expect(reopened.ownerEvents.map(\.kind) == ["resolved", "reopened"])

        // A stale status with a reopen as the last status event still shows no closer.
        let stale = DetailModel.make(AskDetail(item: ask(minimal(), status: "done"), events: reopened.events))
        #expect(stale.closedBy == nil)

        let closedAgain = DetailModel.make(AskDetail(
            item: ask(minimal(), status: "dismissed"),
            events: reopened.events + [event(4, "declined", "owner", at: secondClose)]))
        #expect(closedAgain.closedBy == "owner")
        #expect(closedAgain.closedAt == secondClose)
    }

    @Test func ownerEventsKeepOnlyOwnerActions() {
        let detail = AskDetail(item: ask(minimal()), events: [
            event(1, "posted", "session"),
            event(2, "reply", "owner", "hi"),
            event(3, "resolved", "session"),
            event(4, "reopened", "owner"),
            event(5, "steps", "owner"),
        ])
        #expect(detail.ownerEvents.map(\.seq) == [2, 4])
        #expect(Event.ownerKinds.contains("reopened"))
    }

    @Test func lastCloseEventWins() {
        let detail = AskDetail(
            item: ask(minimal(), status: "dismissed"),
            events: [
                event(1, "posted", "session"),
                event(2, "resolved", "session", at: firstClose),
                event(3, "declined", "owner", at: secondClose),
                event(4, "reply", "owner", "late note", at: secondClose),
            ])
        let model = DetailModel.make(detail)
        #expect(model.closedBy == "owner")
        #expect(model.closedAt == secondClose)
    }
}

@Suite struct TicksTests {
    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suite = "relay.tests.ticks.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }

    @Test func keyFormat() {
        #expect(Ticks.key(sourceKey: "local", id: askID) == "relay.ticks.local.\(askID)")
        #expect(Ticks.key(sourceKey: "mailbox:mail.example.com", id: "a") == "relay.ticks.mailbox:mail.example.com.a")
    }

    @Test func saveAndLoad() throws {
        try withDefaults { defaults in
            #expect(Ticks.load(defaults, sourceKey: "local", id: "a").isEmpty)
            Ticks.save(defaults, sourceKey: "local", id: "a", ticks: [2, 0])
            #expect(Ticks.load(defaults, sourceKey: "local", id: "a") == [0, 2])
            #expect(defaults.array(forKey: "relay.ticks.local.a") as? [Int] == [0, 2])
            #expect(Ticks.load(defaults, sourceKey: "mailbox:mail.example.com", id: "a").isEmpty)
            Ticks.save(defaults, sourceKey: "local", id: "a", ticks: [])
            #expect(defaults.object(forKey: "relay.ticks.local.a") == nil)
        }
    }

    @Test func pruneTouchesOnlyItsOwnSource() throws {
        try withDefaults { defaults in
            Ticks.save(defaults, sourceKey: "local", id: "a", ticks: [0])
            Ticks.save(defaults, sourceKey: "local", id: "b", ticks: [1])
            Ticks.save(defaults, sourceKey: "mailbox:mail.example.com", id: "a", ticks: [0])
            Ticks.save(defaults, sourceKey: "mailbox:mail.example.com.other", id: "c", ticks: [0])

            Ticks.prune(defaults, sourceKey: "local", keep: ["a"])
            #expect(Ticks.load(defaults, sourceKey: "local", id: "a") == [0])
            #expect(Ticks.load(defaults, sourceKey: "local", id: "b").isEmpty)
            #expect(Ticks.load(defaults, sourceKey: "mailbox:mail.example.com", id: "a") == [0])

            Ticks.prune(defaults, sourceKey: "mailbox:mail.example.com", keep: [])
            #expect(Ticks.load(defaults, sourceKey: "mailbox:mail.example.com", id: "a").isEmpty)
            #expect(Ticks.load(defaults, sourceKey: "mailbox:mail.example.com.other", id: "c") == [0])
            #expect(Ticks.load(defaults, sourceKey: "local", id: "a") == [0])
        }
    }
}

@Suite struct NodeTreeTests {
    private let steps = [
        Step(action: "Create a channel", place: "Slack"),
        Step(action: "Create the app", place: "api.example.com", substeps: [
            Step(action: "Click Create New App", url: "https://api.example.com/apps"),
            Step(action: "Name it Acme", place: "  "),
            Step(action: "Add the scope", code: "chat:write"),
        ]),
        Step(action: "Invite the bot", substeps: []),
    ]

    @Test func pathsLabelsAndChildren() {
        let nodes = DetailModel.nodes(steps: steps, verify: Step(action: "Check it", code: "ls"))
        #expect(nodes.map(\.path) == ["1", "2", "3", "verify"])
        #expect(nodes[1].children.map(\.path) == ["2.1", "2.2", "2.3"])
        #expect(nodes[1].children.map(\.label) == ["2a", "2b", "2c"])
        #expect(nodes[1].children.map(\.level) == [.sub(2, 0), .sub(2, 1), .sub(2, 2)])
        #expect(nodes[1].children.allSatisfy { $0.kind == .sub && $0.number == 2 && $0.index == 1 })
        #expect(nodes[1].isParent && !nodes[0].isParent && !nodes[2].isParent)
        #expect(nodes[2].children.isEmpty)
        #expect(nodes[3].isVerify && nodes[3].children.isEmpty && nodes[3].number == 4 && nodes[3].level == .verify)
        #expect(nodes[0].level == .top(1))
        #expect(nodes[1].children[1].content.place == nil)
        #expect(nodes.map(\.index) == [0, 1, 2, 3])
        #expect(nodes.map(\.id) == nodes.map(\.path))
    }

    @Test func fingerprints() {
        let nodes = DetailModel.nodes(steps: steps, verify: Step(action: "Check it", code: "ls"))
        let parent = StepFingerprint.make(kind: .step, action: "Create the app", place: "api.example.com", code: nil)
        #expect(nodes[1].fingerprint == parent)
        #expect(nodes[1].children[2].fingerprint
            == StepFingerprint.make(kind: .sub, action: "Add the scope", place: nil, code: "chat:write", parent: parent))
        #expect(nodes[3].fingerprint == StepFingerprint.make(kind: .verify, action: "Check it", place: nil, code: "ls"))
        #expect(nodes[1].children[1].fingerprint
            == StepFingerprint.make(kind: .sub, action: "Name it Acme", place: nil, code: nil, parent: parent))
    }

    @Test func allTenLettersAndNoMore() {
        let many = Step(action: "Many", substeps: (1...12).map { Step(action: "s\($0)") })
        let nodes = DetailModel.nodes(steps: [many], verify: nil)
        #expect(nodes[0].children.map(\.label) == ["1a", "1b", "1c", "1d", "1e", "1f", "1g", "1h", "1i", "1j"])
        #expect(nodes[0].children.last?.path == "1.10")
    }

    @Test func forwardersForTheOldView() {
        let node = DetailModel.nodes(steps: [Step(action: "A", place: "P", code: "c", lang: "l", expect: "e", detail: "d", url: "u")], verify: nil)[0]
        #expect([node.action, node.place, node.code, node.lang, node.expect, node.detail, node.url]
            == ["A", "P", "c", "l", "e", "d", "u"])
        #expect(!node.isVerify)
    }
}
