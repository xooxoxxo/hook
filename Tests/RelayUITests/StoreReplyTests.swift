import Foundation
import RelayCore
import Testing
@testable import RelayUI

private let choiceAsk = item("q", created: stamp(minutesAgo: 5), reply: ReplySpec(prompt: "Where?", choices: ["A", "B"]))
private let plain = [item("a", created: stamp(minutesAgo: 10)), item("b", created: stamp(minutesAgo: 20))]

@Suite @MainActor struct StoreReplyTests {
    @Test func aDraftSurvivesBackOpenAndPolls() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let store = Store(defaults: defaults.defaults)
        await start(store, FakeQueueSource(items: plain))
        store.open("a")
        store.drafts["a"] = "half a thought"
        store.back()
        await store.refresh()
        store.open("b")
        store.open("a")
        #expect(store.drafts["a"] == "half a thought")
        #expect(store.primaryAction(for: "a") == .sendAndDone)
        #expect(store.primaryAction(for: "b") == .done)
    }

    @Test func aSentReplyClearsTheDraft() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let clock = TestClock()
        let store = Store(defaults: defaults.defaults, now: { clock.now })
        let fake = FakeQueueSource(items: plain)
        await start(store, fake)
        store.drafts["a"] = "C07QX2"
        #expect(await store.sendReply("a"))
        #expect(store.drafts["a"] == nil)
        #expect(store.replyStates["a"] == .sent(at: ClockText.time(clock.now)))
        #expect(await fake.replies["a"] == ["C07QX2"])
        #expect(store.replyLines(for: "a").map(\.text) == ["C07QX2"])
        #expect(!(await store.sendReply("a")))
    }

    @Test func aFailedSendKeepsTheDraftAndDoesNotClose() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let store = Store(defaults: defaults.defaults)
        let fake = FakeQueueSource(items: plain)
        await start(store, fake)
        await fake.failNext(QueueError.unreachable("timed out"), on: "reply")
        store.open("a")
        store.drafts["a"] = "hello"
        await store.sendAndDone("a")
        #expect(store.drafts["a"] == "hello")
        #expect(store.pending.isEmpty)
        #expect(store.navigation.selectedID == "a")
        #expect(store.replyStates["a"] == .failed(reason: "timed out"))
    }

    @Test func sendAndDoneSendsThenCloses() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let store = Store(defaults: defaults.defaults)
        let fake = FakeQueueSource(items: plain)
        await start(store, fake)
        store.open("a")
        store.drafts["a"] = "done here"
        await store.sendAndDone("a")
        #expect(await fake.replies["a"] == ["done here"])
        #expect(store.pending.contains("a"))
        #expect(store.navigation.selectedID == "b")
        await store.sendAndDone("b")
        #expect(store.pending.contains("b"))
        #expect(await fake.replies["b"] == nil)
    }

    @Test func choiceSentStateComesFromEvents() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let store = Store(defaults: defaults.defaults)
        let fake = FakeQueueSource(items: [choiceAsk], details: [
            "q": AskDetail(item: choiceAsk, events: [Event(seq: 1, itemId: "q", kind: "reply", actor: "owner",
                                                           text: "choice: B", at: "2026-10-16T09:30:00+00:00")]),
        ])
        await start(store, fake)
        store.open("q")
        #expect(await eventually { store.details["q"] != nil })
        #expect(store.latestSentChoice(for: "q") == 1)
        store.pendingChoice["q"] = 1
        #expect(store.primaryAction(for: "q") == .done)
        store.pendingChoice["q"] = 0
        #expect(store.primaryAction(for: "q") == .sendAndDone)
        #expect(await store.sendChoice("q"))
        #expect(await fake.replies["q"] == ["choice: A"])
        #expect(store.pendingChoice["q"] == nil)
        #expect(store.latestSentChoice(for: "q") == 0)
        #expect(store.replyLines(for: "q").map(\.text) == ["You chose: B", "You chose: A"])
    }

    @Test func draftsAndChoicesAreNeverWritten() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let store = Store(defaults: defaults.defaults)
        await start(store, FakeQueueSource(items: [choiceAsk]))
        store.drafts["q"] = "a private note only in memory"
        store.pendingChoice["q"] = 1
        let values = defaults.defaults.dictionaryRepresentation().values.map { "\($0)" }
        #expect(!values.contains { $0.contains("a private note only in memory") })
        #expect(!defaults.defaults.dictionaryRepresentation().keys.contains { $0.contains("draft") || $0.contains("choice") })
    }

    @Test func theSentCaptionReturnsToIdleAfterTheHold() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let store = Store(defaults: defaults.defaults, sentHold: .milliseconds(20))
        await start(store, FakeQueueSource(items: plain))
        store.drafts["a"] = "short hold"
        #expect(await store.sendReply("a"))
        guard case .sent = store.replyStates["a"] else {
            Issue.record("expected .sent, got \(String(describing: store.replyStates["a"]))")
            return
        }
        #expect(await eventually { store.replyStates["a"] == .idle })
    }

    @Test func anEarlierTimerDoesNotClearALaterSend() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let gate = SleepGate()
        let clock = TestClock()
        let store = Store(defaults: defaults.defaults, now: { clock.now }, sleep: { _ in await gate.wait() })
        await start(store, FakeQueueSource(items: plain))
        store.drafts["a"] = "first"
        #expect(await store.sendReply("a"))
        store.drafts["a"] = "second"
        #expect(await store.sendReply("a"))
        // Both sends fall in the same minute, so their .sent states are equal.
        let sent = ReplyBoxState.sent(at: ClockText.time(clock.now))
        #expect(store.replyStates["a"] == sent)
        #expect(await eventually { await gate.waiting == 2 })
        await gate.release(0)
        // Give the first timer every chance to run.
        for _ in 0..<20 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(30))
        #expect(store.replyStates["a"] == sent)
        await gate.release(1)
        #expect(await eventually { store.replyStates["a"] == .idle })
    }

    /// A reply that comes back after a swap belongs to the old source: no state, no Notice.
    @Test func aReplyThatFinishesAfterASwapChangesNothing() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let store = Store(defaults: defaults.defaults)
        let old = FakeQueueSource(items: plain)
        await start(store, old)
        store.open("a")
        await old.holdReplies()
        store.drafts["a"] = "late"
        let send = Task { await store.sendReply("a") }
        #expect(await eventually { await old.heldReplyCount == 1 })
        #expect(store.replyStates["a"] == .sending)
        store.swap(to: FakeQueueSource(items: plain), identity: mailboxIdentity, pollSeconds: 3600)
        await old.releaseReplies()
        #expect(await send.value == false)
        #expect(await old.replies["a"] == ["late"])
        #expect(store.replyStates["a"] == nil)
        #expect(store.notice == nil)
    }

    /// The same for a send that fails after the swap: the old source's error posts nothing.
    @Test func aReplyThatFailsAfterASwapChangesNothing() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let store = Store(defaults: defaults.defaults)
        let old = FakeQueueSource(items: plain)
        await start(store, old)
        await old.holdReplies()
        await old.failNext(QueueError.storeFailed("disk full"), on: "reply")
        store.drafts["a"] = "late"
        let send = Task { await store.sendReply("a") }
        #expect(await eventually { await old.heldReplyCount == 1 })
        store.swap(to: FakeQueueSource(items: plain), identity: mailboxIdentity, pollSeconds: 3600)
        await old.releaseReplies()
        #expect(await send.value == false)
        #expect(store.replyStates["a"] == nil)
        #expect(store.notice == nil)
    }
}

/// A sleep the test ends by hand, in the order the sleeps started.
private actor SleepGate {
    private var continuations: [CheckedContinuation<Void, Never>?] = []
    var waiting: Int { continuations.count }
    func wait() async { await withCheckedContinuation { continuations.append($0) } }
    func release(_ index: Int) {
        continuations[index]?.resume()
        continuations[index] = nil
    }
}
