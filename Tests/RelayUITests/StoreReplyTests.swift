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
        #expect(store.selectedID == "a")
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
        #expect(store.selectedID == "b")
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
}
