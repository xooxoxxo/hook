import Foundation

/// `stepWait` on the single-item wire: the wait the Pond enforces on the owner's Done.
public struct ServedStepWait: Codable, Sendable, Equatable {
    public var id: String?
    public var path: String
    /// ISO 8601, as served.
    public var until: String

    public init(id: String?, path: String, until: String) {
        self.id = id; self.path = path; self.until = until
    }
}

/// After the owner answers a `then: "steps"` question, Done waits for the session's next steps:
/// until a revision later than the answer arrives, or 10 minutes pass. The Pond's rule: the wait
/// starts at the newest owner `answer` event for that question's path; with several on, the one
/// that ends first wins. Skip always works.
public struct StepWait: Equatable, Sendable {
    public static let thenSteps = "steps"
    /// STEP_WAIT_S.
    public static let seconds: TimeInterval = 600
    /// The action bar's line while Done waits.
    public static let waitingText = "Waiting for next steps…"
    /// Behind the bar's "?".
    public static let helpText = "The session said more steps follow your answer. "
        + "Done comes back when they arrive, or after 10 minutes."

    public var stepID: String?
    public var path: String
    public var until: Date

    public init(stepID: String?, path: String, until: Date) {
        self.stepID = stepID; self.path = path; self.until = until
    }

    /// The Pond's `stepWait`; nil when `until` doesn't read as a time.
    public init?(_ served: ServedStepWait) {
        guard let until = Timestamp.date(served.until) else { return nil }
        self.init(stepID: served.id, path: served.path, until: until)
    }

    /// The wait on now. With `pondServesWaits` (the Pond lists `appendSteps` and the item came
    /// from a single-item route) the Pond decides: its `stepWait` while it hasn't ended, else none,
    /// and nothing is computed here. Otherwise the Pond's rule (`requirements.step_waits`) runs
    /// on `ins` (the version in force), the ask's events and every revision's `at`, as served.
    public static func current(_ ins: Instructable, events: [Event], revisionTimes: [String], now: Date,
                               pond: StepWait? = nil, pondServesWaits: Bool = false) -> StepWait? {
        if pondServesWaits || pond != nil { return pond.flatMap { now < $0.until ? $0 : nil } }
        let revised = events.filter { $0.kind == "revised" }.map(\.seq)
        let stamps = revisionTimes.compactMap(Timestamp.date)
        var best: StepWait?
        for entry in StepIdentity.entries(ins) where entry.step.question?.waitsForSteps == true {
            guard let newest = newestAnswer(events, id: entry.step.id, path: entry.path),
                  let answered = Timestamp.date(newest.at) else { continue }
            if revised.contains(where: { $0 > newest.seq }) || stamps.contains(where: { $0 > answered }) { continue }
            let until = answered.addingTimeInterval(seconds)
            guard now < until else { continue }
            if best.map({ until < $0.until }) ?? true {
                best = StepWait(stepID: entry.step.id, path: entry.path, until: until)
            }
        }
        return best
    }

    /// The owner's answer with the highest seq to the question at `id` / `path`: matched by step
    /// id when both the step and the answer carry one, else by path. The first of equal seqs wins.
    static func newestAnswer(_ events: [Event], id: String?, path: String) -> Event? {
        var newest: Event?
        for event in events where event.kind == "answer" && event.actor == "owner" {
            guard let text = event.text, case .object(let body)? = try? JSONValue.parse(Data(text.utf8)) else { continue }
            let matches: Bool
            if let id, case .string(let answered)? = body["id"] {
                matches = answered == id
            } else {
                matches = body["step"] == .string(path)
            }
            if matches, newest.map({ event.seq > $0.seq }) ?? true { newest = event }
        }
        return newest
    }
}
