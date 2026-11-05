import Foundation
import Testing
@testable import RelayCore

@Suite struct SharedProgressTests {
    private func detail(_ bodies: [Instructable], accepted: Int? = nil, events: [Event]) throws -> AskDetail {
        var previous = ""
        var revisions: [Revision] = []
        for (index, ins) in bodies.enumerated() {
            let body = String(decoding: try JSONEncoder().encode(ins), as: UTF8.self)
            let rev = index + 1
            let hash = RevisionHash.make(rev: rev, prev: previous, at: "2026-01-01T00:00:00Z", reason: "", body: body)
            revisions.append(Revision(rev: rev, hash: hash, prev: previous, at: "2026-01-01T00:00:00Z", reason: "", body: body))
            previous = hash
        }
        let last = revisions.last!
        var item = WireItem(id: "a", title: "Shared steps", status: "open", created: last.at, updated: last.at,
                            payload: Payload(instructable: bodies.last!))
        item.revision = ServedRevision(rev: last.rev, hash: last.hash, prev: last.prev, at: last.at,
                                      reason: last.reason, body: last.body, acceptedRev: accepted ?? last.rev)
        return AskDetail(item: item, events: events, revisions: revisions)
    }
    private var body: Instructable {
        Instructable(v: 1, title: "Shared steps", steps: [Step(action: "Build", code: "make", id: "s1"), Step(action: "Check", id: "s2")])
    }
    private func event(_ seq: Int, _ text: String, rev: Int = 1, actor: String = "owner") -> Event {
        Event(seq: seq, itemId: "a", kind: "progress", actor: actor, text: text, at: "", rev: rev)
    }
    @Test func eventsFoldBySequenceOnEveryAsk() throws {
        let events = [event(3, #"{"tick":[],"untick":["s1"]}"#), event(1, #"{"tick":["s1"],"untick":[]}"#),
                      event(2, #"{"tick":["s2"],"untick":[]}"#)]
        #expect(try SharedProgress.fold(detail: detail([body], events: events)) == ["s2"])
        #expect(try SharedProgress.fold(detail: detail([body], events: Array(events.reversed()))) == ["s2"])
    }
    @Test func onlyVerifiedAcceptedBodyCountsAndRequiredChangesKeepTicks() throws {
        var required = body
        required.steps[0].required = true
        var changed = required
        changed.steps[0].code = "make release"
        let events = [event(1, #"{"tick":["s1","s2"],"untick":[]}"#)]
        #expect(try SharedProgress.fold(detail: detail([body, required], events: events)) == ["s1", "s2"])
        #expect(try SharedProgress.fold(detail: detail([body, required, changed], accepted: 2, events: events)) == ["s1", "s2"])
        #expect(try SharedProgress.fold(detail: detail([body, required, changed], events: events)) == ["s2"])
        var bad = try detail([body], events: events)
        bad.revisions[0].body += " "
        #expect(throws: HistoryProblem.self) { try SharedProgress.fold(detail: bad) }
    }
    @Test func malformedForeignAndUnknownRevisionEventsAreIgnored() throws {
        let events = [event(1, "bad"), event(2, #"{"tick":["s1"]}"#, actor: "session"),
                      event(3, #"{"tick":["s1"]}"#, rev: 99), event(4, #"{"tick":["missing","s2"]}"#)]
        #expect(try SharedProgress.fold(detail: detail([body], events: events)) == ["s2"])
    }
    @Test func legacyBodyDoesNotExcuseMissingRevisionHistory() throws {
        let events = [event(1, #"{"tick":["s1"]}"#)]
        var legacy = try detail([body], events: events)
        legacy.item.revision = nil
        legacy.revisions = []
        #expect(try SharedProgress.fold(detail: legacy) == ["s1"])
        var incomplete = try detail([body], events: events)
        incomplete.revisions = []
        #expect(throws: HistoryProblem.missing) { try SharedProgress.fold(detail: incomplete) }
    }
    @Test func unknownOwnFieldsParticipateInTickIdentity() throws {
        let events = [event(1, #"{"tick":["s1"]}"#)]
        var value = try detail([body], events: events)
        let first = value.revisions[0]
        var object = try #require(try JSONSerialization.jsonObject(with: Data(first.body.utf8)) as? [String: Any])
        var steps = try #require(object["steps"] as? [[String: Any]])
        steps[0]["futureField"] = "new owner-visible content"
        object["steps"] = steps
        let raw = String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        let hash = RevisionHash.make(rev: 2, prev: first.hash, at: first.at, reason: "", body: raw)
        value.revisions.append(Revision(rev: 2, hash: hash, prev: first.hash, at: first.at, reason: "", body: raw))
        value.item.revision = ServedRevision(rev: 2, hash: hash, prev: first.hash, at: first.at, reason: "", body: raw, acceptedRev: 2)
        #expect(try SharedProgress.fold(detail: value) == [])
    }

    @Test func orphanRevisionHistoryCannotFallBackToLegacyPayload() throws {
        let events = [event(1, #"{"tick":["s1"]}"#)]
        var orphan = try detail([body], events: events)
        orphan.item.revision = nil
        #expect(throws: HistoryProblem.missing) { try SharedProgress.fold(detail: orphan) }
        orphan.revisions[0].body += " "
        #expect(throws: HistoryProblem.missing) { try SharedProgress.fold(detail: orphan) }
    }

    @Test func malformedPresentMetadataRemainsDistinctFromAbsentAfterDecodingAndRoundtrip() throws {
        var legacy = try detail([body], events: [event(1, #"{"tick":["s1"]}"#)])
        legacy.item.revision = nil
        legacy.revisions = []
        let encoded = try JSONEncoder().encode(legacy)
        #expect(try SharedProgress.fold(detail: JSONDecoder().decode(AskDetail.self, from: encoded)) == ["s1"])
        var absent = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        absent.removeValue(forKey: "revisions")
        let absentDetail = try JSONDecoder().decode(AskDetail.self, from: JSONSerialization.data(withJSONObject: absent))
        #expect(try SharedProgress.fold(detail: absentDetail) == ["s1"])
        for field in ["revision", "revisions"] {
            for malformed: Any in [NSNull(), "invalid", ["rev": "invalid"]] {
                var object = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
                if field == "revision" {
                    var item = try #require(object["item"] as? [String: Any])
                    item[field] = malformed
                    object["item"] = item
                } else { object[field] = malformed }
                let data = try JSONSerialization.data(withJSONObject: object)
                let decoded = try JSONDecoder().decode(AskDetail.self, from: data)
                #expect(throws: HistoryProblem.missing) { try SharedProgress.fold(detail: decoded) }
                let roundtrip = try JSONDecoder().decode(AskDetail.self, from: JSONEncoder().encode(decoded))
                #expect(throws: HistoryProblem.missing) { try SharedProgress.fold(detail: roundtrip) }
            }
        }
    }
    @Test func payloadRawIdentityPreservesRoundtripAndInvalidatesOnTypedMutation() throws {
        let made = Payload(instructable: body)
        #expect(try JSONDecoder().decode(Payload.self, from: JSONEncoder().encode(made)) == made)
        let raw = #"{"instructable":{"title":"Shared steps","steps":[{"id":"s1","do":"Build","futureField":"first"}]}}"#
        var decoded = try JSONDecoder().decode(Payload.self, from: Data(raw.utf8))
        #expect(try JSONValue.parse(JSONEncoder().encode(decoded)) == JSONValue.parse(Data(raw.utf8)))
        decoded.instructable?.steps[0].action = "Changed"
        let changed = try JSONValue.parse(JSONEncoder().encode(decoded))
        guard case .array(let steps)? = changed["instructable"]?["steps"] else { Issue.record("No steps"); return }
        #expect(steps[0]["do"] == .string("Changed"))
        #expect(steps[0]["futureField"] == nil)
        #expect(try JSONDecoder().decode(Payload.self, from: JSONEncoder().encode(decoded)) == decoded)
    }

}
