import Foundation
import RelayCore
import Testing
@testable import RelayUI

private let feedback = Question(prompt: "Anything to change?")
private let region = Question(prompt: "Which region?", choices: ["EU", "US"])

/// "o": 1 optional question, 2 a required question, 3 an optional parent asking its own question
/// with a plain sub-step.
private func optionalItem() -> WireItem {
    let ins = Instructable(v: 1, title: "Ask o", urgency: "today", steps: [
        Step(action: "Tell us what you think", question: feedback, optional: true),
        Step(action: "Pick the region", question: region),
        Step(action: "Review", substeps: [Step(action: "Read the notes")], question: feedback, optional: true),
    ])
    let created = stamp(minutesAgo: 5)
    return WireItem(id: "o", title: "Ask o", status: "open", projectId: "Acme", created: created, updated: created,
                    payload: Payload(why: nil, cmd: nil, link: nil, instructable: ins))
}

@Suite @MainActor struct StoreOptionalTests {
    @Test func anOptionalQuestionTicksDoneWithoutAnAnswer() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let store = Store(defaults: defaults.defaults)
        await start(store, FakeQueueSource(items: [optionalItem()]))
        store.open("o")
        #expect(store.detail("o")?.current == "1")
        store.toggleTick("1", in: "o")
        #expect(store.detail("o")?.ticks == ["1"])
        #expect(store.detail("o")?.current == "2")
        store.toggleTick("2", in: "o")                     // a required question can't be ticked
        #expect(store.detail("o")?.ticks == ["1"])
    }

    @Test func cmdTTicksAnOptionalCurrentStepAndStopsAtARequiredQuestion() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let store = Store(defaults: defaults.defaults)
        await start(store, FakeQueueSource(items: [optionalItem()]))
        store.open("o")
        #expect(store.tickCurrent(in: "o") == "1")
        #expect(store.tickCurrent(in: "o") == nil)         // 2 needs an answer
        #expect(store.untickLast(in: "o") == "1")
    }

    @Test func onlyRequiredQuestionsAreInTheUnansweredCaption() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let store = Store(defaults: defaults.defaults)
        await start(store, FakeQueueSource(items: [optionalItem()]))
        store.open("o")
        #expect(store.detail("o")?.unansweredCaption == "1 question unanswered")
    }

    @Test func anOptionalParentsOwnTickSurvivesAReload() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let store = Store(defaults: defaults.defaults)
        await start(store, FakeQueueSource(items: [optionalItem()]))
        store.open("o")
        store.toggleTick("3", in: "o")
        #expect(store.detail("o")?.ticks == ["3", "3.1"])
        #expect(store.detail("o")?.progress == StepProgress(done: 2, total: 4))

        let again = Store(defaults: defaults.defaults)
        await start(again, FakeQueueSource(items: [optionalItem()]))
        again.open("o")
        #expect(again.detail("o")?.ticks == ["3", "3.1"])
    }
}
