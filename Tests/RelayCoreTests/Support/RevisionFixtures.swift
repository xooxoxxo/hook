import Foundation
@testable import RelayCore

/// An instructable's body as a revision serves it: sorted keys, slashes unescaped. The client
/// hashes the string as served, so any stable JSON will do in tests.
func revisionBody(_ ins: Instructable) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return String(decoding: try! encoder.encode(ins), as: UTF8.self)
}

/// A hashed chain of revisions, rev 1 first; `reasons[i]` is rev i+2's reason.
func revisionChain(_ bodies: [Instructable], reasons: [String] = []) -> [Revision] {
    var chain: [Revision] = []
    for (index, ins) in bodies.enumerated() {
        let rev = index + 1, prev = chain.last?.hash ?? "", at = "2026-10-29T10:0\(index):00+00:00"
        let reason = index == 0 ? "" : (reasons.indices.contains(index - 1) ? reasons[index - 1] : "Fix step \(rev)")
        let body = revisionBody(ins)
        chain.append(Revision(rev: rev, hash: RevisionHash.make(rev: rev, prev: prev, at: at, reason: reason, body: body),
                              prev: prev, at: at, reason: reason, body: body))
    }
    return chain
}

func served(_ revision: Revision, acceptedRev: Int? = nil) -> ServedRevision {
    ServedRevision(rev: revision.rev, hash: revision.hash, prev: revision.prev, at: revision.at, reason: revision.reason,
                   body: revision.body, acceptedRev: acceptedRev)
}

/// An open ask whose payload says `payloadTitle` steps while its revisions carry `bodies`.
func revisedDetail(_ bodies: [Instructable], id: String = "a", reasons: [String] = [], acceptedRev: Int? = nil,
                   payload: Instructable? = nil) -> AskDetail {
    let chain = revisionChain(bodies, reasons: reasons)
    let item = WireItem(id: id, title: bodies[0].title, status: "open", projectId: "Acme",
                        created: "2026-10-29T10:00:00+00:00", updated: "2026-10-29T10:0\(chain.count):00+00:00",
                        payload: Payload(instructable: payload ?? bodies[0]),
                        revision: served(chain[chain.count - 1], acceptedRev: acceptedRev ?? chain.count))
    return AskDetail(item: item, events: [], revisions: chain)
}

/// "Deploy" with `count` steps s1…sN, each with `code` "run N" unless `codes` says otherwise.
func idSteps(_ count: Int, codes: [Int: String] = [:], title: String = "Deploy") -> Instructable {
    Instructable(v: 1, title: title, urgency: "today",
                 steps: (1...count).map { Step(action: "Step \($0)", code: codes[$0] ?? "run \($0)", id: "s\($0)") })
}
