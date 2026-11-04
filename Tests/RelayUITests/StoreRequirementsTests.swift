import Foundation
import RelayCore
import Testing
@testable import RelayUI

private let pond13 = PondVersion.semver(SemVer(major: 1, minor: 3, patch: 0))
private let pond12 = PondVersion.semver(SemVer(major: 1, minor: 2, patch: 0))
private let question = Question(prompt: "Which environment?")

/// An open ask "Ask <id>" with these steps (ids s1, s2, …, given by the caller) and requirements.
private func requiredAsk(_ id: String, _ steps: [Step], reply: ReplySpec? = nil, done: [String]? = nil) -> WireItem {
    let created = stamp(minutesAgo: 5)
    let ins = Instructable(v: 1, title: "Ask \(id)", urgency: "today", steps: steps, reply: reply, done: done)
    return WireItem(id: id, title: "Ask \(id)", status: "open", projectId: "Acme", created: created, updated: created,
                    payload: Payload(instructable: ins))
}

/// Step 1 plain, step 2 required.
private func twoSteps(_ id: String = "a", done: [String]? = nil) -> WireItem {
    requiredAsk(id, [Step(action: "Open", id: "s1"), Step(action: "Rotate", required: true, id: "s2")], done: done)
}

/// A sleep the test ends by hand: `releaseAll` resumes every sleep waiting now.
private actor SleepGate {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    var waiting: Int { continuations.count }
    func wait() async { await withCheckedContinuation { continuations.append($0) } }
    func releaseAll() {
        let all = continuations
        continuations = []
        all.forEach { $0.resume() }
    }
}

@MainActor private final class Beeps {
    var count = 0
}

@Suite @MainActor struct StoreRequirementsTests {
    private func started(_ defaults: TestDefaults, items: [WireItem], identity: SourceIdentity = mailboxIdentity,
                         pond: PondVersion? = pond13, clock: TestClock = TestClock(),
                         gate: SleepGate? = nil) async -> (Store, FakeQueueSource) {
        let sleep: @Sendable (Duration) async throws -> Void
        if let gate {
            sleep = { @Sendable _ in await gate.wait() }
        } else {
            sleep = { @Sendable _ in }
        }
        let store = Store(defaults: defaults.defaults, now: { clock.now }, sleep: sleep)
        let fake = FakeQueueSource(items: items)
        await start(store, fake, identity: identity)
        store.setPond(pond)
        for item in items { await store.reload(item.id) }
        return (store, fake)
    }

    // MARK: Sending progress

    @Test func ticksQueueAndSendOneDebouncedDelta() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let gate = SleepGate()
        let (store, fake) = await started(defaults, items: [twoSteps()], gate: gate)
        store.toggleTick("1", in: "a")
        store.toggleTick("2", in: "a")
        #expect(await eventually { await gate.waiting == 2 })
        #expect(await fake.count("progress") == 0)
        await gate.releaseAll()
        #expect(await eventually { await fake.count("progress") == 1 })
        try? await Task.sleep(for: .milliseconds(30))
        let sent = await fake.progresses
        #expect(sent.count == 1)
        #expect(sent.first?.tick == ["s1", "s2"])
        #expect(sent.first?.untick == [])
    }

    @Test func aTickThenAnUntickSendsNothing() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let gate = SleepGate()
        let (store, fake) = await started(defaults, items: [twoSteps()], gate: gate)
        store.toggleTick("2", in: "a")
        store.toggleTick("2", in: "a")
        // The untick emptied the outbox: its debounce was stopped, and none started.
        #expect(await eventually { await gate.waiting == 1 })
        await gate.releaseAll()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await fake.count("progress") == 0)
    }

    @Test func noProgressOnPond120OnThisMacOrWithoutRequirements() async {
        let old = TestDefaults()
        defer { old.drop() }
        let (store, fake) = await started(old, items: [twoSteps()], pond: pond12)
        store.toggleTick("2", in: "a")
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await fake.count("progress") == 0)
        #expect(store.notice == nil)

        let local = TestDefaults()
        defer { local.drop() }
        let (mac, macFake) = await started(local, items: [twoSteps()], identity: localIdentity, pond: nil)
        mac.toggleTick("2", in: "a")
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await macFake.count("progress") == 0)

        let plain = TestDefaults()
        defer { plain.drop() }
        let (none, noneFake) = await started(plain, items: [item("a", created: stamp(minutesAgo: 5), steps: 2)])
        none.toggleTick("1", in: "a")
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await noneFake.count("progress") == 0)
    }

    @Test func anUnknownPondHoldsTheProgressUntilTheVersionCheckAnswers() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let (store, fake) = await started(defaults, items: [twoSteps()], pond: nil)
        store.toggleTick("2", in: "a")
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await fake.count("progress") == 0)
        store.setPond(pond13)
        #expect(await eventually { await fake.count("progress") == 1 })
        #expect(await fake.progresses.first?.tick == ["s2"])
    }

    @Test func aFailedProgressIsKeptForTheNextTick() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let (store, fake) = await started(defaults, items: [twoSteps()])
        await fake.failNext(QueueError.unreachable("offline"), on: "progress")
        store.toggleTick("2", in: "a")
        #expect(await eventually { await fake.count("progress") == 1 })
        #expect(store.notice == nil)
        store.toggleTick("1", in: "a")
        #expect(await eventually { await fake.progresses.count == 1 })
        #expect(await fake.progresses.last?.tick == ["s1", "s2"])
    }

    // MARK: The gate

    @Test func doneIsRefusedWhileSomethingIsLeft() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let (store, fake) = await started(defaults, items: [twoSteps()])
        store.open("a")
        #expect(!store.doneAllowed("a"))
        store.close("a", .done)
        #expect(store.undoInfo == nil)
        #expect(store.items.map(\.id) == ["a"])
        #expect(store.navigation.selectedID == "a")
        store.toggleTick("2", in: "a")
        #expect(store.doneAllowed("a"))
        store.close("a", .done)
        #expect(store.undoInfo?.verdict == .done)
        #expect(await fake.count("resolve") == 0)
    }

    @Test func commandReturnDoesNothingAndBeeps() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let (store, _) = await started(defaults, items: [twoSteps(), item("b", created: stamp(minutesAgo: 9))])
        let beeps = Beeps()
        store.shell.beep = { beeps.count += 1 }
        store.listSelection = "a"
        store.perform(.done)
        store.perform(.warnUnsent)
        store.perform(.sendAndDone)
        #expect(store.undoInfo == nil)
        #expect(beeps.count == 3)
        store.open("a")
        store.perform(.done)
        #expect(store.undoInfo == nil)
        #expect(beeps.count == 4)
        // An ask without requirements closes as before.
        store.back()
        store.listSelection = "b"
        store.perform(.done)
        #expect(store.undoInfo?.title == "Ask b")
        #expect(beeps.count == 4)
    }

    @Test func theContextMenuDoneIsDisabledWithItsReason() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let (store, _) = await started(defaults, items: [twoSteps()])
        let disabled = ContextMenuEntry.disabled(title: "Done", reason: "Open it and finish the marked items first")
        let row = store.queue.rows["a"]
        #expect(row?.doneBlocked == true)
        #expect(row.map { QueueContextMenu.entries(for: $0, filter: nil, localHost: nil) }?.contains(disabled) == true)
        store.toggleTick("2", in: "a")
        #expect(store.queue.rows["a"]?.doneBlocked == false)
        let entries = store.queue.rows["a"].map { QueueContextMenu.entries(for: $0, filter: nil, localHost: nil) } ?? []
        #expect(entries.contains(.item(title: "Done", command: .done, shortcut: "⌘↩")))
    }

    @Test func anAskWithoutACachedDetailIsBlockedFromTheQueue() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let store = Store(defaults: defaults.defaults, now: { fixedNow }, sleep: { _ in })
        let fake = FakeQueueSource(items: [twoSteps()])
        for _ in 0..<5 { await fake.failNext(QueueError.unreachable("offline"), on: "get a") }
        await start(store, fake, identity: mailboxIdentity)
        #expect(store.detail(for: "a") == nil)
        #expect(store.queue.rows["a"]?.doneBlocked == true)
        #expect(!store.doneAllowed("a"))
    }

    @Test func doneFlushesProgressBeforeTheResolve() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let gate = SleepGate()
        let clock = TestClock()
        let (store, fake) = await started(defaults, items: [twoSteps()], clock: clock, gate: gate)
        store.toggleTick("2", in: "a")
        #expect(await eventually { await gate.waiting == 1 })
        store.close("a", .done)
        clock.advance(11)
        store.sendDue()
        #expect(await eventually { await fake.count("resolve") == 1 })
        let calls = await fake.calls.filter { $0.hasPrefix("progress") || $0.hasPrefix("resolve") }
        #expect(calls == ["progress a", "resolve a done"])
        await gate.releaseAll()
        try? await Task.sleep(for: .milliseconds(30))
        #expect(await fake.count("progress") == 1)
    }

    @Test func a409PostsDoneRefusedReloadsAndSendsTheTicksAgain() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let clock = TestClock()
        let (store, fake) = await started(defaults, items: [twoSteps()], clock: clock)
        store.toggleTick("2", in: "a")
        #expect(await eventually { await fake.count("progress") == 1 })
        await fake.failNext(QueueError.requirementsUnmet(left: [PondRequirement(kind: "step", id: "s2", path: "2")]),
                            on: "resolve")
        store.close("a", .done)
        let loads = await fake.count("get a")
        clock.advance(11)
        store.sendDue()
        #expect(await eventually { store.notice == .doneRefused(id: "a", title: "Ask a") })
        #expect(store.items.map(\.id) == ["a"])
        #expect(await eventually { await fake.count("get a") > loads })
        #expect(await eventually { await fake.count("progress") == 2 })
        #expect(await fake.progresses.last?.tick == ["s2"])
        // No automatic retry.
        try? await Task.sleep(for: .milliseconds(30))
        #expect(await fake.count("resolve") == 1)
        #expect(store.notice?.actionTitle == "Show")
    }

    // MARK: Send & Done (RD 22)

    @Test func sendAndDoneWithAnAnswerCoveringTheLastRequiredQuestionSendsThenCloses() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let ask = requiredAsk("a", [Step(action: "Pick", question: question, required: true, id: "s1")])
        let (store, fake) = await started(defaults, items: [ask])
        store.open("a")
        store.answerDrafts["a"] = ["1": .text("Staging")]
        #expect(store.doneAllowed("a"))
        let snapshot = store.detail("a")
        #expect(snapshot?.doneEnabled == true)
        #expect(snapshot?.discardEnabled == false)
        #expect(snapshot?.primary == .sendAndDone)
        // Discard & Done would leave the requirement unmet: refused, and the draft stays.
        store.discardAndDone("a")
        #expect(store.answerDrafts["a"]?["1"] == .text("Staging"))
        #expect(store.undoInfo == nil)
        await store.sendAndDone("a")
        #expect(await fake.count("answer") == 1)
        #expect(store.undoInfo?.verdict == .done)
    }

    @Test func withAMessageAlsoLeftSendAndDoneDoesNotClose() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let ask = requiredAsk("a", [Step(action: "Pick", question: question, required: true, id: "s1")],
                              done: ["message"])
        let (store, fake) = await started(defaults, items: [ask])
        store.open("a")
        store.answerDrafts["a"] = ["1": .text("Staging")]
        #expect(!store.doneAllowed("a"))
        #expect(store.detail("a")?.doneEnabled == false)
        await store.sendAndDone("a")
        #expect(store.undoInfo == nil)
        #expect(await fake.count("resolve") == 0)
        // Once the owner messages the session, Done turns on.
        #expect(await store.sendMessage("a", text: "Rotated on staging"))
        #expect(store.detail("a")?.requirements.marksMessages == false)
        await store.sendAndDone("a")
        #expect(store.undoInfo?.verdict == .done)
    }

    @Test func skipAlwaysCloses() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let (store, _) = await started(defaults, items: [twoSteps(done: ["message"])])
        store.open("a")
        store.close("a", .declined)
        #expect(store.undoInfo?.verdict == .declined)
    }

    // MARK: The snapshot

    @Test func theSnapshotSaysWhatIsLeftAndHidesTheUnansweredCaption() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let ask = requiredAsk("a", [Step(action: "Open", id: "s1"),
                                    Step(action: "Pick", question: question, required: true, id: "s2"),
                                    Step(action: "Other", question: Question(prompt: "Anything else?"), id: "s3")])
        let (store, _) = await started(defaults, items: [ask])
        store.open("a")
        let left = store.detail("a")
        #expect(left?.requirements.hasAny == true)
        #expect(left?.requirements.marks("2") == true)
        #expect(left?.doneEnabled == false)
        #expect(left?.discardEnabled == false)
        #expect(left?.unansweredCaption == nil)

        let plainDefaults = TestDefaults()
        defer { plainDefaults.drop() }
        var plain = ask
        plain.id = "p"
        plain.payload.instructable?.steps[1].required = nil
        let (other, _) = await started(plainDefaults, items: [plain])
        other.open("p")
        let snapshot = other.detail("p")
        #expect(snapshot?.requirements == RequirementState.none)
        #expect(snapshot?.doneEnabled == true)
        #expect(snapshot?.discardEnabled == true)
        #expect(snapshot?.unansweredCaption != nil)
    }
}
