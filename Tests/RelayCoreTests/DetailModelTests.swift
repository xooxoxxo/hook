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
                     expect: "stored"),
            ],
            verify: Step(action: "The job log shows success", code: "tail -n 5 job.log"),
            reply: ReplySpec(prompt: "Which region?", choices: ["eu", "us"]),
            links: [LinkRef(label: "Runbook", url: "https://example.com/runbook")],
            from: Origin(session: "s-42", host: "build-mac", cwd: "/work/acme"))
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
        #expect(model.provenance == "build-mac · /work/acme · s-42")
        #expect(model.project == "Acme")
        #expect(model.urgency == "now")
        #expect(model.nodes == [
            DetailModel.Node(index: 0, action: "Open the key page", place: "Browser", url: "https://example.com/keys"),
            DetailModel.Node(index: 1, action: "Store the new key", place: "Terminal", code: "echo stored",
                             lang: "bash", expect: "stored"),
            DetailModel.Node(index: 2, isVerify: true, action: "The job log shows success", code: "tail -n 5 job.log"),
        ])
        #expect(model.links == [LinkRef(label: "Runbook", url: "https://example.com/runbook")])
        #expect(model.reply == ReplySpec(prompt: "Which region?", choices: ["eu", "us"]))
        #expect(model.ownerReplies == ["choice: eu"])
        #expect(model.isOpen)
        #expect(model.closedBy == nil)
        #expect(model.closedAt == nil)
        #expect(DetailModel.make(item: detail.item, events: detail.events) == model)
    }

    @Test func provenanceKeepsOnlyPresentParts() {
        let hostAndSession = DetailModel.make(AskDetail(
            item: ask(minimal(from: Origin(session: "s-42", host: "build-mac", cwd: "  "))), events: []))
        #expect(hostAndSession.provenance == "build-mac · s-42")
        let cwdOnly = DetailModel.make(AskDetail(item: ask(minimal(from: Origin(cwd: "/work/acme"))), events: []))
        #expect(cwdOnly.provenance == "/work/acme")
        let none = DetailModel.make(AskDetail(item: ask(minimal(from: Origin())), events: []))
        #expect(none.provenance == nil)
        #expect(DetailModel.make(AskDetail(item: ask(minimal()), events: [])).provenance == nil)
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
        #expect(model.nodes == [DetailModel.Node(index: 0, action: "Run this", code: "relay --version")])
        #expect(model.links == [LinkRef(label: "Link", url: "https://example.com/x")])
        #expect(model.notes == ["Then restart the job"])
        #expect(model.reply == nil)
        #expect(model.provenance == nil)
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
