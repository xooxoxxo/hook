import Foundation
import Testing
@testable import RelayCore

/// append-vectors.json: Hook's own check that a revision only adds steps at the end. The
/// `append` cases are for writers and the Pond; Swift runs `check` and `chain`.
private enum AppendVectors {
    static let cases: [JSONValue] = {
        guard let url = Bundle.module.url(forResource: "append-vectors", withExtension: "json", subdirectory: "Fixtures"),
              let data = try? Data(contentsOf: url), case .array(let items)? = (try? JSONValue.parse(data))?["cases"] else {
            return []
        }
        return items
    }()

    static func names(_ kind: String) -> [String] {
        cases.filter { $0["kind"]?.stringValue == kind }.compactMap { $0["name"]?.stringValue }
    }

    static func named(_ name: String) throws -> JSONValue {
        try #require(cases.first { $0["name"]?.stringValue == name })
    }
}

/// A body text read strictly, as a revision body is.
private func raw(_ text: String) throws -> ExactJSON { try RevisionBody.read(text).raw }

private func int(_ value: JSONValue?) -> Int? {
    if case .int(let number)? = value { return number }
    return nil
}

/// One hex digit of `hash` flipped, as the vectors' `tamper` says.
private func flipped(_ hash: String) -> String {
    guard let first = hash.first else { return hash }
    return (first == "0" ? "1" : "0") + hash.dropFirst()
}

/// A chain case as a fetched detail: the newest revision is the item's.
private func detail(_ item: JSONValue) throws -> AskDetail {
    guard case .array(let entries)? = item["revisions"] else { throw AppendTestError.noRevisions }
    let tamper = int(item["tamper"]?["rev"])
    var revisions: [Revision] = []
    for entry in entries {
        let rev = try #require(int(entry["rev"]))
        var hash = try #require(entry["hash"]?.stringValue)
        if rev == tamper { hash = flipped(hash) }
        revisions.append(Revision(rev: rev, hash: hash, prev: try #require(entry["prev"]?.stringValue),
                                  at: try #require(entry["at"]?.stringValue),
                                  reason: try #require(entry["reason"]?.stringValue),
                                  body: try #require(entry["body"]?.stringValue)))
    }
    let last = try #require(revisions.last)
    let first = try RevisionBody.parse(revisions[0].body)
    let wire = WireItem(id: "a", title: first.title, status: "open", created: revisions[0].at, updated: last.at,
                        payload: Payload(instructable: first),
                        revision: ServedRevision(rev: last.rev, hash: last.hash, prev: last.prev, at: last.at,
                                                 reason: last.reason, body: last.body, acceptedRev: 1))
    return AskDetail(item: wire, events: [], revisions: revisions)
}

private enum AppendTestError: Error { case noRevisions }

/// Bodies of "Ask" with the given step ids, each step "Step <id>".
private func body(_ ids: [String], why: String = "Because") -> String {
    let steps = ids.map { #"{"do":"Step \#($0)","id":"\#($0)"}"# }.joined(separator: ",")
    return #"{"steps":[\#(steps)],"title":"Ask","urgency":"today","v":1,"why":"\#(why)"}"#
}

/// A fetched, verified history of `bodies`, rev 1 first, with the revisions at 10:01, 10:02, …
private func history(_ bodies: [String], reasons: [String] = []) throws -> VerifiedHistory {
    var revisions: [Revision] = []
    for (index, text) in bodies.enumerated() {
        let rev = index + 1, prev = revisions.last?.hash ?? "", at = "2026-11-14T10:0\(rev):00+00:00"
        let reason = index == 0 ? "" : (reasons.indices.contains(index - 1) ? reasons[index - 1] : "Rev \(rev)")
        revisions.append(Revision(rev: rev, hash: RevisionHash.make(rev: rev, prev: prev, at: at, reason: reason, body: text),
                                  prev: prev, at: at, reason: reason, body: text))
    }
    let last = revisions[revisions.count - 1]
    let first = try RevisionBody.parse(bodies[0])
    let wire = WireItem(id: "a", title: first.title, status: "open", created: revisions[0].at, updated: last.at,
                        payload: Payload(instructable: first),
                        revision: ServedRevision(rev: last.rev, hash: last.hash, prev: last.prev, at: last.at,
                                                 reason: last.reason, body: last.body, acceptedRev: 1))
    guard case .success(let verified)? = RevisionCheck.verify(AskDetail(item: wire, events: [], revisions: revisions)) else {
        throw AppendTestError.noRevisions
    }
    return verified
}

private func ownerAnswer(at: String, kind: String = "answer", actor: String = "owner") -> Event {
    Event(seq: 1, itemId: "a", kind: kind, actor: actor, text: "Friday", at: at, rev: 1)
}

@Suite struct AppendCheckTests {
    @Test func theVectorsAreThere() {
        #expect(AppendVectors.names("check").count >= 10)
        #expect(AppendVectors.names("chain").count >= 5)
    }

    @Test(arguments: AppendVectors.names("check"))
    func checkCases(_ name: String) throws {
        let item = try AppendVectors.named(name)
        let base = try raw(try #require(item["base"]?.stringValue))
        let next = try raw(try #require(item["next"]?.stringValue))
        let expected = try #require(item["expect"]?["append"])
        #expect(.bool(AppendCheck.isAppend(base: base, next: next)) == expected, "\(name)")
    }

    /// Tampered cases fail the history check first; the rest are current exactly when every
    /// revision after the accepted one is an append.
    @Test(arguments: AppendVectors.names("chain"))
    func chainCases(_ name: String) throws {
        let item = try AppendVectors.named(name)
        let accepted = try #require(int(item["accepted"]))
        let state = try #require(item["expect"]?["state"]?.stringValue)
        let verified = try #require(RevisionCheck.verify(try detail(item)))
        switch verified {
        case .failure(let problem):
            #expect(state == "historyChanged", "\(name): \(problem)")
            #expect(item["tamper"] != nil, "\(name)")
        case .success(let history):
            #expect(item["tamper"] == nil, "\(name)")
            let current = history.current.rev == accepted || AppendCheck.appendedSince(history, base: accepted) == true
            #expect(current == (state == "current"), "\(name)")
            #expect(AppendCheck.appendedSince(history, base: accepted) != nil, "\(name)")
        }
    }

    @Test func historyKeepsEachRawBody() throws {
        let verified = try history([body(["s1"]), body(["s1", "s2"])])
        #expect(verified.raw[1] == (try raw(body(["s1"]))))
        #expect(verified.raw[2] == (try raw(body(["s1", "s2"]))))
    }

    @Test func aBaseAtTheCurrentRevisionHasNothingToCheck() throws {
        let verified = try history([body(["s1"]), body(["s1", "s2"])])
        #expect(AppendCheck.appendedSince(verified, base: 2) == true)
        #expect(AppendCheck.appendedSince(verified, base: 3) == nil)
        #expect(AppendCheck.appendedSince(verified, base: 0) == nil)
        #expect(AppendCheck.markers(verified, base: 2, events: []) == [])
    }

    /// The owner answered between rev 1 (10:01) and rev 2 (10:02): "Added after your answer".
    @Test func markerAfterAnswer() throws {
        let verified = try history([body(["s1"]), body(["s1", "r2-1", "r2-2"])], reasons: ["Two more checks"])
        let markers = AppendCheck.markers(verified, base: 1, events: [ownerAnswer(at: "2026-11-14T10:01:30+00:00")])
        #expect(markers == [AppendMarker(rev: 2, at: "2026-11-14T10:02:00+00:00", note: "Two more checks",
                                         firstStepID: "r2-1", addedTopLevel: 2, afterAnswer: true, firstStepIndex: 1)])
    }

    /// No owner answer in between, or one outside the window, or one by the session: "Added by the session".
    @Test func markerBySession() throws {
        let verified = try history([body(["s1"]), body(["s1", "r2-1"]), body(["s1", "r2-1", "r3-1"])],
                                   reasons: ["One more", "And another"])
        let events = [ownerAnswer(at: "2026-11-14T10:00:30+00:00"),
                      ownerAnswer(at: "2026-11-14T10:02:30+00:00", actor: "session"),
                      ownerAnswer(at: "2026-11-14T10:04:00+00:00")]
        let markers = AppendCheck.markers(verified, base: 1, events: events)
        #expect(markers.map(\.rev) == [2, 3])
        #expect(markers.map(\.afterAnswer) == [false, false])
        #expect(markers.map(\.firstStepID) == ["r2-1", "r3-1"])
        #expect(markers.map(\.note) == ["One more", "And another"])
        #expect(markers.map(\.addedTopLevel) == [1, 1])
    }

    /// Only append revisions get a marker; a correction in the middle gets none.
    @Test func markersSkipACorrection() throws {
        let verified = try history([body(["s1"]), body(["s1", "s2"], why: "Changed"), body(["s1", "s2", "r3-1"], why: "Changed")])
        #expect(AppendCheck.markers(verified, base: 1, events: []).map(\.rev) == [3])
        #expect(AppendCheck.appendedSince(verified, base: 1) == false)
        #expect(AppendCheck.appendedSince(verified, base: 2) == true)
    }

    /// The run of appends that ends at a revision starts after the last revision that wasn't one.
    @Test func runStartFindsTheLastNonAppend() throws {
        let appends = try history([body(["s1"]), body(["s1", "s2"]), body(["s1", "s2", "s3"])])
        #expect(AppendCheck.runStart(appends, through: 3) == 1)
        #expect(AppendCheck.runStart(appends, through: 1) == 1)
        let fixed = try history([body(["s1"]), body(["s1", "s2"], why: "Changed"), body(["s1", "s2", "s3"], why: "Changed")])
        #expect(AppendCheck.runStart(fixed, through: 3) == 2)
        #expect(AppendCheck.runStart(fixed, through: 2) == 2)
    }

    /// A list item merged on top of a fetched rev 1 past a gap: rev 2's body is missing.
    @Test func missingBodyIsNil() throws {
        let fetched = try history([body(["s1"])])
        let full = try history([body(["s1"]), body(["s1", "r2-1"]), body(["s1", "r2-1", "r3-1"])])
        let three = try #require(full.stamps[3])
        let text = body(["s1", "r2-1", "r3-1"])
        let listedItem = WireItem(id: "a", title: "Ask", status: "open", created: "2026-11-14T10:01:00+00:00",
                                  updated: "2026-11-14T10:03:00+00:00",
                                  payload: Payload(instructable: try RevisionBody.parse(body(["s1"]))),
                                  revision: ServedRevision(rev: 3, hash: three.hash, prev: try #require(full.prevs[3]),
                                                           at: "2026-11-14T10:03:00+00:00", reason: "Rev 3", body: text,
                                                           acceptedRev: 1))
        let listed = RevisionCheck.verify(listed: listedItem)
        guard case .success(let lonely)? = listed else { Issue.record("listed rev 3 didn't verify"); return }
        #expect(lonely.raw[3] == (try raw(text)))
        guard case .success(let merged)? = RevisionCheck.merge(fetched: .success(fetched), listed: listed) else {
            Issue.record("merge failed")
            return
        }
        #expect(merged.current.rev == 3)
        #expect(merged.raw[3] == (try raw(text)))
        #expect(merged.raw[2] == nil)
        #expect(AppendCheck.appendedSince(merged, base: 1) == nil)
        #expect(AppendCheck.markers(merged, base: 1, events: []) == [])
    }

    @Test func isAppendNeedsObjectsWithStepArrays() throws {
        let one = try raw(body(["s1"]))
        #expect(!AppendCheck.isAppend(base: .array([]), next: one))
        #expect(!AppendCheck.isAppend(base: one, next: .object([.init(key: "steps", value: .string("x"))])))
        // An old step's value changed type (1 to "1"): not an append.
        let number = try raw(#"{"steps":[{"do":"a","n":1}],"title":"T","v":1}"#)
        let text = try raw(#"{"steps":[{"do":"a","n":"1"},{"do":"b"}],"title":"T","v":1}"#)
        #expect(!AppendCheck.isAppend(base: number, next: text))
        let same = try raw(#"{ "v" : 1, "title":"T", "steps":[{"n":1, "do":"a"},{"do":"b"}]}"#)
        #expect(AppendCheck.isAppend(base: number, next: same))
    }

    /// Strict reading refuses an object whose keys are canonically equivalent (NFC and NFD
    /// "é"), raw or escaped, so the exact key comparison never meets two keys it would merge.
    @Test func canonicallyEquivalentKeysAreRefused() {
        for text in ["{\"caf\u{e9}\":1,\"cafe\u{301}\":1,\"steps\":[],\"title\":\"T\",\"v\":1}",
                     #"{"caf\u00e9":1,"cafe\u0301":1,"steps":[],"title":"T","v":1}"#] {
            #expect(throws: RevisionBodyError.duplicateKey) { try RevisionBody.read(text) }
        }
    }

    /// Numbers compare by their source text; escaped and raw strings by what they decode to.
    @Test func numbersByTextStringsByScalars() throws {
        let one = try raw(#"{"steps":[{"do":"a","n":1}],"title":"T","v":1}"#)
        #expect(!AppendCheck.isAppend(base: one, next: try raw(#"{"steps":[{"do":"a","n":1.0},{"do":"b"}],"title":"T","v":1}"#)))
        #expect(!AppendCheck.isAppend(base: one, next: try raw(#"{"steps":[{"do":"a","n":1e0},{"do":"b"}],"title":"T","v":1}"#)))
        let escaped = try raw(#"{"steps":[{"do":"caf\u00e9"}],"title":"T","v":1}"#)
        #expect(AppendCheck.isAppend(base: escaped, next: try raw("{\"steps\":[{\"do\":\"caf\u{e9}\"},{\"do\":\"b\"}],\"title\":\"T\",\"v\":1}")))
        #expect(!AppendCheck.isAppend(base: escaped, next: try raw("{\"steps\":[{\"do\":\"cafe\u{301}\"},{\"do\":\"b\"}],\"title\":\"T\",\"v\":1}")))
    }
}
