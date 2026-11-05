import Foundation
import RelayCore
@testable import RelayUI

/// An instructable's body as a revision serves it: any stable JSON will do, as Hook hashes the served string.
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

/// "Ask <id>" with steps s1…sN ("Step N", code "run N" unless `codes` says otherwise).
func idSteps(_ count: Int, id: String = "a", codes: [Int: String] = [:], urls: [Int: String] = [:],
             verify: Step? = nil) -> Instructable {
    Instructable(v: 1, title: "Ask \(id)", urgency: "today",
                 steps: (1...count).map {
                     Step(action: "Step \($0)", code: codes[$0] ?? "run \($0)", url: urls[$0], id: "s\($0)")
                 }, verify: verify)
}

/// An open ask whose revisions carry `bodies`, its payload saying `payload` (rev 1's body by
/// default), as the list serves it and as its detail does.
func revised(_ id: String, _ bodies: [Instructable], reasons: [String] = [], acceptedRev: Int? = nil,
             payload: Instructable? = nil, created: String = stamp(minutesAgo: 10),
             events: [Event] = []) -> (item: WireItem, detail: AskDetail) {
    let chain = revisionChain(bodies, reasons: reasons)
    let last = chain[chain.count - 1]
    let item = WireItem(id: id, title: bodies[0].title, status: "open", projectId: "Acme", created: created,
                        updated: "2026-10-29T10:0\(chain.count):00+00:00",
                        payload: Payload(instructable: payload ?? bodies[0]),
                        revision: ServedRevision(rev: last.rev, hash: last.hash, prev: last.prev, at: last.at,
                                                 reason: last.reason, body: last.body,
                                                 acceptedRev: acceptedRev ?? chain.count))
    return (item, AskDetail(item: item, events: events, revisions: chain))
}

/// A Store whose review records live in `secrets` and a temp `reviews.json`, once it has read them.
@MainActor func reviewingStore(_ defaults: TestDefaults, secrets: MemorySecretStore = MemorySecretStore(),
                               url: URL = reviewsURL(), now: (@MainActor () -> Date)? = nil) async -> Store {
    let store = Store(defaults: defaults.defaults, now: now ?? { fixedNow },
                      reviews: ReviewPersistence(secrets: secrets, url: url))
    await store.reviewsLoaded()
    return store
}

func reviewsURL() -> URL {
    FileManager.default.temporaryDirectory.appending(path: "relay-reviews-\(UUID().uuidString).json")
}

/// What the shell was asked to copy, open and confirm.
@MainActor final class ShellRecorder {
    var copied: [String] = []
    var opened: [URL] = []
    var presenceAsked: [String] = []
    /// What `confirmPresence` answers.
    var presence = true

    var shell: PanelShellActions {
        var shell = PanelShellActions(hide: {}, setUp: {}, quit: {}, dock: { _ in }, openSettings: { _ in },
                                      copy: { [weak self] in self?.copied.append($0) },
                                      openURL: { [weak self] in self?.opened.append($0) })
        shell.confirmPresence = { [weak self] reason in
            guard let self else { return false }
            self.presenceAsked.append(reason)
            return self.presence
        }
        return shell
    }
}

/// This Mac accepted `stamp` of `id`: the record as an accept leaves it, without the Pond call.
@MainActor func markAccepted(_ store: Store, _ id: String, _ stamp: RevisionStamp) {
    var record = store.record(id) ?? ReviewRecord()
    record.accepted = stamp
    store.setRecord(record, for: id)
    store.rerender(id)
}
