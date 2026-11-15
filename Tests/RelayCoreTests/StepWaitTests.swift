import Foundation
import Testing
@testable import RelayCore

private let answeredAt = "2026-11-14T10:00:00+00:00"
private let t0 = Timestamp.date(answeredAt)!

/// Step 2 asks a question that waits for the session's next steps; step 3 one that doesn't.
private func ask(then: String? = "steps") -> Instructable {
    Instructable(v: 1, title: "Deploy", urgency: "today", steps: [
        Step(action: "Open the settings", id: "s1"),
        Step(action: "Pick a target", question: Question(prompt: "Where?", choices: ["Staging", "Prod"], then: then),
             id: "s2"),
        Step(action: "Pick a day", question: Question(prompt: "When?", choices: ["Now", "Friday"]), id: "s3"),
    ])
}

private func answer(_ path: String, at: String, seq: Int = 1, actor: String = "owner") -> Event {
    Event(seq: seq, itemId: "a", kind: "answer", actor: actor, text: #"{"step":"\#(path)","picked":["Staging"]}"#,
          at: at, rev: 1)
}

@Suite struct StepWaitTests {
    @Test func theWaitIsTenMinutes() {
        #expect(StepWait.seconds == 600)
    }

    @Test func waitAfterAnswer() {
        let wait = StepWait.current(ask(), events: [answer("2", at: answeredAt)], revisionTimes: [1: "2026-11-14T09:50:00+00:00"],
                                    now: t0.addingTimeInterval(60))
        #expect(wait == StepWait(stepID: "s2", path: "2", until: t0.addingTimeInterval(600)))
        // No answer, a question without then, or an answer by someone else: no wait.
        #expect(StepWait.current(ask(), events: [], revisionTimes: [:], now: t0) == nil)
        #expect(StepWait.current(ask(then: nil), events: [answer("2", at: answeredAt)], revisionTimes: [:], now: t0) == nil)
        #expect(StepWait.current(ask(), events: [answer("3", at: answeredAt)], revisionTimes: [:], now: t0) == nil)
        #expect(StepWait.current(ask(), events: [answer("2", at: answeredAt, actor: "session")], revisionTimes: [:],
                                 now: t0) == nil)
    }

    /// The newest answer to the question starts the wait.
    @Test func theNewestAnswerStartsIt() {
        let later = "2026-11-14T10:05:00+00:00"
        let wait = StepWait.current(ask(), events: [answer("2", at: answeredAt, seq: 1), answer("2", at: later, seq: 2)],
                                    revisionTimes: [2: "2026-11-14T10:03:00+00:00"], now: t0.addingTimeInterval(400))
        #expect(wait?.until == t0.addingTimeInterval(300 + 600))
    }

    @Test func waitEndsOnRevision() {
        let events = [answer("2", at: answeredAt)]
        #expect(StepWait.current(ask(), events: events, revisionTimes: [1: "2026-11-14T09:50:00+00:00",
                                                                        2: "2026-11-14T10:01:00+00:00"],
                                 now: t0.addingTimeInterval(120)) == nil)
        // A revision at the same second as the answer doesn't end it: it must be later.
        #expect(StepWait.current(ask(), events: events, revisionTimes: [2: answeredAt], now: t0.addingTimeInterval(1)) != nil)
    }

    @Test func waitEndsAfter600s() {
        let events = [answer("2", at: answeredAt)]
        #expect(StepWait.current(ask(), events: events, revisionTimes: [:], now: t0.addingTimeInterval(599)) != nil)
        #expect(StepWait.current(ask(), events: events, revisionTimes: [:], now: t0.addingTimeInterval(600)) == nil)
    }

    /// Several waits on: the one that ends first wins. A sub-step's question counts too.
    @Test func theEarliestEndingWaitWins() {
        var ins = ask()
        ins.steps[2].question?.then = "steps"
        ins.steps[0].substeps = [Step(action: "Sub", question: Question(prompt: "Ok?", then: "steps"), id: "s1.1")]
        let events = [answer("3", at: "2026-11-14T10:02:00+00:00", seq: 1), answer("1.1", at: answeredAt, seq: 2),
                      answer("2", at: "2026-11-14T10:04:00+00:00", seq: 3)]
        let wait = StepWait.current(ins, events: events, revisionTimes: [:], now: t0.addingTimeInterval(300))
        #expect(wait == StepWait(stepID: "s1.1", path: "1.1", until: t0.addingTimeInterval(600)))
    }

    /// The Pond's own `stepWait` wins over the local rule while it hasn't ended.
    @Test func pondStepWaitWins() {
        let pond = StepWait(stepID: "s3", path: "3", until: t0.addingTimeInterval(900))
        #expect(StepWait.current(ask(), events: [answer("2", at: answeredAt)], revisionTimes: [:], now: t0,
                                 pond: pond) == pond)
        #expect(StepWait.current(ask(), events: [], revisionTimes: [:], now: t0.addingTimeInterval(900), pond: pond) == nil)
        let served = ServedStepWait(id: "s3", path: "3", until: "2026-11-14T10:15:00+00:00")
        #expect(StepWait(served) == pond)
        #expect(StepWait(ServedStepWait(id: nil, path: "3", until: "soon")) == nil)
    }
}
