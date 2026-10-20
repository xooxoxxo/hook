import Foundation
import RelayCore
@testable import RelayUI

let fixedNow = Timestamp.date("2026-10-16T09:40:00+00:00")!

/// A created stamp `minutes` before fixedNow.
func stamp(minutesAgo minutes: Double) -> String {
    Timestamp.string(fixedNow.addingTimeInterval(-minutes * 60))
}

/// An open instructable ask titled "Ask <id>" with `steps` steps; `substeps[i]` gives step i (0-based) that many sub-steps.
func item(_ id: String, project: String = "Acme", urgency: String = "today", created: String, steps: Int = 1,
          substeps: [Int: Int] = [:], reply: ReplySpec? = nil) -> WireItem {
    let list = (0..<steps).map { i in
        Step(action: "Step \(i + 1)", substeps: substeps[i].map { n in (0..<n).map { Step(action: "Sub \(i + 1).\($0 + 1)") } })
    }
    let ins = Instructable(v: 1, title: "Ask \(id)", urgency: urgency, steps: list, reply: reply)
    return WireItem(id: id, title: "Ask \(id)", status: "open", projectId: project, created: created, updated: created,
                    payload: Payload(why: nil, cmd: nil, link: nil, instructable: ins))
}

/// The same ask, closed.
func closed(_ item: WireItem, status: String = "done") -> WireItem {
    var copy = item
    copy.status = status
    copy.completedAt = stamp(minutesAgo: 30)
    return copy
}

@MainActor final class TestClock {
    var now = fixedNow
    func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
}

/// A private UserDefaults suite; call `drop()` at the end of the test.
struct TestDefaults {
    let name = "relay.tests.store.\(UUID().uuidString)"
    var defaults: UserDefaults { UserDefaults(suiteName: name)! }
    func drop() { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
}

let localIdentity = SourceIdentity(key: SourceKey.local, mailbox: nil)
let mailboxIdentity = SourceIdentity(
    key: "mailbox:mailbox.example#personal",
    mailbox: MailboxSettings(url: URL(string: "https://mailbox.example")!, tokenFile: "/tmp/relay-example-token", context: "personal"))

/// Polls `condition` every 10 ms for up to 2 s.
@MainActor func eventually(_ condition: @MainActor () async -> Bool) async -> Bool {
    let end = ContinuousClock.now + .seconds(2)
    while ContinuousClock.now < end {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}

/// Swaps `store` to `source` and waits until the first list (started by the poll loop) is done.
@MainActor func start(_ store: Store, _ source: FakeQueueSource, identity: SourceIdentity = localIdentity) async {
    store.swap(to: source, identity: identity, pollSeconds: 3600)
    _ = await eventually { await source.count("list") >= 1 }
    await store.refresh()
}
