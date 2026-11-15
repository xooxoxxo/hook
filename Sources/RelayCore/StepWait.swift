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

    /// The wait on now. `pond`, the item's `stepWait`, wins while it hasn't ended; without one
    /// the rule runs here on `ins` (the version in force), the ask's events and each revision's `at`.
    public static func current(_ ins: Instructable, events: [Event], revisionTimes: [Int: String], now: Date,
                               pond: StepWait? = nil) -> StepWait? {
        if let pond { return now < pond.until ? pond : nil }
        let answers = Answers.latest(events)
        let revisions = revisionTimes.values.compactMap(Timestamp.date)
        var best: StepWait?
        for entry in StepIdentity.entries(ins) where entry.step.question?.waitsForSteps == true {
            guard let answer = answers[entry.path], let answered = Timestamp.date(answer.at) else { continue }
            let until = answered.addingTimeInterval(seconds)
            guard now < until, !revisions.contains(where: { $0 > answered }) else { continue }
            if best.map({ until < $0.until }) ?? true {
                best = StepWait(stepID: entry.step.id, path: entry.path, until: until)
            }
        }
        return best
    }
}
