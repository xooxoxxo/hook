import Foundation
import Testing
@testable import RelayCore

/// Fixtures/revision-vectors.json: the Pond's shared vectors (gen_revision_vectors).
private func vectors(_ kind: String) throws -> [JSONValue] {
    let url = try #require(Bundle.module.url(
        forResource: "revision-vectors", withExtension: "json", subdirectory: "Fixtures"))
    let root = try JSONValue.parse(Data(contentsOf: url))
    guard root["version"] == .int(1), case .array(let cases)? = root["cases"] else {
        Issue.record("revision-vectors.json has no version 1 cases")
        return []
    }
    return cases.filter { $0["kind"]?.stringValue == kind }
}

private func int(_ value: JSONValue?) -> Int? {
    if case .int(let n)? = value { return n }
    return nil
}

@Suite struct RevisionsTests {
    @Test func everyHashVectorMatches() throws {
        let cases = try vectors("hash")
        #expect(!cases.isEmpty)
        for item in cases {
            let rev = try #require(int(item["rev"]))
            let made = RevisionHash.make(rev: rev, prev: try #require(item["prev"]?.stringValue),
                                         at: try #require(item["at"]?.stringValue),
                                         reason: try #require(item["reason"]?.stringValue),
                                         body: try #require(item["body"]?.stringValue))
            #expect(made == item["hash"]?.stringValue, "\(item["name"]?.stringValue ?? "")")
        }
    }

    @Test func everyCanonicalBodyParsesToItsInput() throws {
        let cases = try vectors("canonical")
        #expect(!cases.isEmpty)
        for item in cases {
            let body = try #require(item["body"]?.stringValue)
            #expect(try JSONValue.parse(Data(body.utf8)) == item["input"], "\(item["name"]?.stringValue ?? "")")
            #expect(!(try OrderedJSON.hasDuplicateKeys(OrderedJSON.parse(Data(body.utf8)))))
        }
        // The canonical instructable reads as an instructable.
        let ins = try #require(cases.first { $0["name"]?.stringValue == "canonical-instructable-with-ids" })
        let parsed = try RevisionBody.parse(try #require(ins["body"]?.stringValue))
        #expect(parsed.steps.map(\.id) == ["s1", "s2", "s3"])
        #expect(parsed.steps[1].substeps?.map(\.id) == ["s2.1", "s2.2"])
    }

    @Test func everyDuplicateKeyBodyIsRefused() throws {
        let cases = try vectors("duplicateKey")
        #expect(cases.count >= 8)
        for item in cases {
            let raw = try #require(item["raw"]?.stringValue)
            #expect(throws: RevisionBodyError.duplicateKey, "\(item["name"]?.stringValue ?? "")") {
                try RevisionBody.parse(raw)
            }
        }
    }

    @Test func aBodyThatIsNotAnInstructableIsRefused() {
        #expect(throws: RevisionBodyError.invalid) { try RevisionBody.parse("[1,2]") }
        #expect(throws: RevisionBodyError.invalid) { try RevisionBody.parse("{\"title\":\"x\"") }
        #expect(throws: RevisionBodyError.invalid) { try RevisionBody.parse("{\"title\":\"a\\ud800\",\"steps\":[]}") }
        #expect(throws: RevisionBodyError.invalid) { try RevisionBody.parse("{\"steps\":[]}") }
    }

    @Test func aWholeHistoryVerifies() throws {
        let detail = revisedDetail([idSteps(3), idSteps(3, codes: [3: "fixed"])], reasons: ["Fix s3"], acceptedRev: 1)
        let history = try RevisionCheck.verify(detail)!.get()
        #expect(history.current == detail.revisions[1].stamp)
        #expect(history.stamps.keys.sorted() == [1, 2])
        #expect(history.bodies[2]?.steps[2].code == "fixed")
        #expect(history.bodies[1]?.steps[2].code == "run 3")
        #expect(history.reasons == [1: "", 2: "Fix s3"])
        #expect(history.acceptedOnPond == 1)
        #expect(history.isComplete)
    }

    @Test func oneChangedByteIsABadHash() throws {
        var detail = revisedDetail([idSteps(3), idSteps(4)])
        detail.revisions[1].body = detail.revisions[1].body.replacingOccurrences(of: "run 4", with: "run 5")
        #expect(RevisionCheck.verify(detail) == .failure(.badHash(2)))
    }

    @Test func aPrevMismatchIsABadChain() throws {
        let one = revisionChain([idSteps(3)])[0]
        let other = revisionChain([idSteps(2), idSteps(4)])
        // Rev 2 hashes correctly over its own fields, but names a different rev 1.
        var detail = revisedDetail([idSteps(3), idSteps(4)])
        detail.revisions = [one, other[1]]
        detail.item.revision = served(other[1])
        #expect(RevisionCheck.verify(detail) == .failure(.badChain(2)))
    }

    @Test func aMissingRevisionOrServedMismatchIsMissing() throws {
        var detail = revisedDetail([idSteps(3), idSteps(4), idSteps(5)])
        detail.revisions.remove(at: 1)
        #expect(RevisionCheck.verify(detail) == .failure(.missing))
        var short = revisedDetail([idSteps(3), idSteps(4)])
        short.revisions = []
        #expect(RevisionCheck.verify(short) == .failure(.missing))
        // The item names a rev the history doesn't reach.
        var behind = revisedDetail([idSteps(3), idSteps(4), idSteps(5)])
        behind.revisions.removeLast()
        #expect(RevisionCheck.verify(behind) == .failure(.missing))
    }

    @Test func anUnreadableBodyNamesItsRev() throws {
        let chain = revisionChain([idSteps(3)])
        let at = "2026-10-29T10:01:00+00:00", body = "{\"title\":\"a\",\"title\":\"b\",\"steps\":[]}"
        let hash = RevisionHash.make(rev: 2, prev: chain[0].hash, at: at, reason: "x", body: body)
        let two = Revision(rev: 2, hash: hash, prev: chain[0].hash, at: at, reason: "x", body: body)
        var detail = revisedDetail([idSteps(3)])
        detail.revisions = [chain[0], two]
        detail.item.revision = served(two)
        #expect(RevisionCheck.verify(detail) == .failure(.unreadable(2)))
    }

    @Test func anItemWithoutARevisionIsLegacy() {
        var detail = revisedDetail([idSteps(3)])
        detail.item.revision = nil
        #expect(RevisionCheck.verify(detail) == nil)
        #expect(RevisionCheck.verify(listed: detail.item) == nil)
    }

    @Test func aListedItemVerifiesItsCurrentRevisionOnly() throws {
        let detail = revisedDetail([idSteps(3), idSteps(4)])
        let history = try RevisionCheck.verify(listed: detail.item)!.get()
        #expect(history.current.rev == 2)
        #expect(history.bodies.keys.sorted() == [2])
        #expect(!history.isComplete)
        var broken = detail.item
        let tampered = broken.revision!.body.replacingOccurrences(of: "run 4", with: "rm -rf ~")
        broken.revision?.body = tampered
        #expect(RevisionCheck.verify(listed: broken) == .failure(.badHash(2)))
    }

    @Test func pinsCatchARollback() throws {
        let two = try RevisionCheck.verify(revisedDetail([idSteps(3), idSteps(4)]))!.get()
        let one = try RevisionCheck.verify(revisedDetail([idSteps(3)]))!.get()
        #expect(RevisionCheck.checkPins(one, pins: [2: two.current.hash]) == .rolledBack)
        #expect(RevisionCheck.checkPins(one, pins: [1: "other"]) == .rolledBack)
        #expect(RevisionCheck.checkPins(two, pins: [1: two.stamps[1]!.hash, 2: two.current.hash]) == nil)
        #expect(RevisionCheck.checkPins(two, pins: [:]) == nil)
    }

    @Test func aListedRevisionExtendsTheFetchedHistory() throws {
        let three = revisedDetail([idSteps(3), idSteps(4), idSteps(5)])
        var two = three
        two.revisions.removeLast()
        two.item.revision = served(two.revisions[1])
        let fetched = RevisionCheck.verify(two)
        let listed = RevisionCheck.verify(listed: three.item)
        let merged = try RevisionCheck.merge(fetched: fetched, listed: listed)!.get()
        #expect(merged.current.rev == 3)
        #expect(merged.bodies.keys.sorted() == [1, 2, 3])
        // The same listed revision keeps the fetched history.
        #expect(RevisionCheck.merge(fetched: fetched, listed: RevisionCheck.verify(listed: two.item)) == fetched)
        // A fetched failure stands until the next fetch.
        #expect(RevisionCheck.merge(fetched: .failure(.missing), listed: listed) == .failure(.missing))
        // The list dropped the revision: the list decides.
        #expect(RevisionCheck.merge(fetched: fetched, listed: nil) == nil)
    }
}
