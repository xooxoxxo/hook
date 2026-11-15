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
/// starts at the newest owner `answer` event for that question that changed its value; with
/// several on, the one that ends first wins. Skip always works.
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

    /// The owner's newest answer to the question at `id` / `path` that changed its value (the
    /// Pond's rule): answers are read in seq order, and one whose (`picked`, `text`) equals the
    /// previous answer's starts nothing new, so an unchanged resend keeps the earlier start.
    /// Matched by step id when both the step and the answer carry one, else by path.
    static func newestAnswer(_ events: [Event], id: String?, path: String) -> Event? {
        let ordered = events.enumerated().sorted { ($0.element.seq, $0.offset) < ($1.element.seq, $1.offset) }
        var newest: Event?
        var value: (picked: JSONValue, text: JSONValue)?
        for event in ordered.map(\.element) where event.kind == "answer" && event.actor == "owner" {
            guard let text = event.text, case .object(let body)? = try? JSONValue.parse(Data(text.utf8)) else { continue }
            let matches: Bool
            if let id, case .string(let answered)? = body["id"] {
                matches = answered == id
            } else {
                matches = body["step"] == .string(path)
            }
            guard matches else { continue }
            let given = (picked: body["picked"] ?? .null, text: body["text"] ?? .null)
            let unchanged = value.map {
                AppendCheck.same($0.picked, given.picked) && AppendCheck.same($0.text, given.text)
            } ?? false
            if newest == nil || !unchanged { newest = event }
            value = given
        }
        return newest
    }
}
