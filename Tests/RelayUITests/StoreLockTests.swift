import Foundation
import RelayCore
import Testing
@testable import RelayUI

private let target = Question(prompt: "Which environment?", choices: ["Staging", "Prod"])
private let name = Question(prompt: "Which name?")

/// "b": 1 plain, 2 blocking, 3 asks (pick), 4 asks (text). 3 and 4 stay locked until 2 is ticked.
private func blockedItem() -> WireItem {
    let ins = Instructable(v: 1, title: "Ask b", urgency: "today", steps: [
        Step(action: "Export the backup"),
        Step(action: "Point the domain", blocking: true, warning: "Wait for DNS"),
        Step(action: "Pick the target", question: target),
        Step(action: "Name the site", question: name),
    ])
    let created = stamp(minutesAgo: 5)
    return WireItem(id: "b", title: "Ask b", status: "open", projectId: "Acme", created: created, updated: created,
                    payload: Payload(why: nil, cmd: nil, link: nil, instructable: ins))
}

@Suite @MainActor struct StoreLockTests {
    @Test func aLockedStepRefusesATick() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let store = Store(defaults: defaults.defaults)
        await start(store, FakeQueueSource(items: [blockedItem()]))
        store.open("b")
        store.toggleTick("4", in: "b")
        #expect(store.detail("b")?.ticks == [])
        store.toggleTick("1", in: "b")
        #expect(store.detail("b")?.ticks == ["1"])
    }

    @Test func tickCurrentTicksTheBlockingStepThenMovesOn() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let store = Store(defaults: defaults.defaults)
        await start(store, FakeQueueSource(items: [blockedItem()]))
        store.open("b")
        #expect(store.tickCurrent(in: "b") == "1")
        #expect(store.detail("b")?.current == "2")
        #expect(store.tickCurrent(in: "b") == "2")
        #expect(store.detail("b")?.current == "3")
        #expect(store.tickCurrent(in: "b") == nil)       // 3 is a question: only an answer completes it
    }

    @Test func lockedDraftsAreNotSentAndOneQuestionSendsAlone() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let store = Store(defaults: defaults.defaults)
        let fake = FakeQueueSource(items: [blockedItem()])
        await start(store, fake)
        store.open("b")
        store.answerDrafts["b"] = ["3": .picked(["Prod"]), "4": .text("Kestrel")]
        #expect(store.unsentAnswers(for: "b") == .none)            // both locked behind step 2
        #expect(store.detail("b")?.unsent.count == 0)
        #expect(!store.keyContext(textFieldFocused: false, popoverOpen: false, closedHeaderFocused: false).hasUnsentAnswers)
        #expect(!(await store.sendAnswers("b")))

        store.toggleTick("2", in: "b")
        #expect(store.unsentAnswers(for: "b").paths == ["3", "4"])
        #expect(await store.sendAnswers("b", only: ["4"]))
        #expect(await fake.answers["b"] == [[Answers.entry(step: "4", text: "Kestrel")]])
        #expect(store.answerDrafts["b"] == ["3": .picked(["Prod"])])
    }
}
