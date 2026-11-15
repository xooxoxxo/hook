import Foundation

/// One revision that only added steps at the end: the divider the detail draws above them.
public struct AppendMarker: Equatable, Sendable {
    public var rev: Int
    /// The revision's `at`, as served.
    public var at: String
    /// The revision's reason: the append call's note.
    public var note: String
    /// The id of the first step it added.
    public var firstStepID: String
    /// How many top-level steps it added ("2 steps added").
    public var addedTopLevel: Int
    /// An owner answer or reply sits between the previous revision's `at` and this one's:
    /// "Added after your answer", else "Added by the session".
    public var afterAnswer: Bool

    public init(rev: Int, at: String, note: String, firstStepID: String, addedTopLevel: Int, afterAnswer: Bool) {
        self.rev = rev; self.at = at; self.note = note; self.firstStepID = firstStepID
        self.addedTopLevel = addedTopLevel; self.afterAnswer = afterAnswer
    }
}

/// Hook's own check that a revision only adds steps at the end (conformance/append-vectors.json).
/// It reads the bodies as served, parsed strictly, and never the Pond's `kind`: the review lock
/// stays Hook's.
public enum AppendCheck {
    /// True when `next.steps` is longer than `base.steps`, every one of `base.steps` is the same
    /// JSON value at the same index of `next.steps` (ids, sub-steps and unknown keys included),
    /// and every other top-level key is in both or neither, with equal values. JSON value
    /// equality ignores key order and white space (`JSONValue` ==).
    public static func isAppend(base: JSONValue, next: JSONValue) -> Bool {
        guard case .object(let old) = base, case .object(let new) = next,
              case .array(let oldSteps)? = old["steps"], case .array(let newSteps)? = new["steps"],
              newSteps.count > oldSteps.count else { return false }
        guard Array(newSteps.prefix(oldSteps.count)) == oldSteps else { return false }
        let oldRest = old.filter { $0.key != "steps" }, newRest = new.filter { $0.key != "steps" }
        return oldRest == newRest
    }

    /// True when every revision from `base + 1` to the current one is `isAppend` of the one
    /// before it (so true when `base` is the current one). nil when a body in `base…current` is
    /// missing, or `base` isn't a revision of this history.
    public static func appendedSince(_ history: VerifiedHistory, base: Int) -> Bool? {
        let current = history.current.rev
        guard base >= 1, base <= current else { return nil }
        guard (base...current).allSatisfy({ history.raw[$0] != nil }) else { return nil }
        for rev in stride(from: base + 1, through: current, by: 1)
        where !isAppend(base: history.raw[rev - 1]!, next: history.raw[rev]!) {
            return false
        }
        return true
    }

    /// Every append revision after `base`, in rev order, each checked against the revision
    /// before it. A revision whose body, or whose previous body, is missing gets none.
    public static func markers(_ history: VerifiedHistory, base: Int, events: [Event]) -> [AppendMarker] {
        let current = history.current.rev
        guard base >= 1, base < current else { return [] }
        var markers: [AppendMarker] = []
        for rev in (base + 1)...current {
            guard let previous = history.raw[rev - 1], let body = history.raw[rev],
                  isAppend(base: previous, next: body),
                  case .array(let oldSteps)? = previous["steps"], case .array(let newSteps)? = body["steps"] else {
                continue
            }
            let at = history.times[rev] ?? ""
            markers.append(AppendMarker(rev: rev, at: at, note: history.reasons[rev] ?? "",
                                        firstStepID: newSteps[oldSteps.count]["id"]?.stringValue ?? "",
                                        addedTopLevel: newSteps.count - oldSteps.count,
                                        afterAnswer: answered(events, after: history.times[rev - 1], before: at)))
        }
        return markers
    }

    /// The owner answers: a step answer or a reply.
    static let answerKinds: Set<String> = ["answer", "reply"]

    /// An owner answer at a time after `after` (exclusive) and up to `before` (inclusive).
    static func answered(_ events: [Event], after: String?, before: String) -> Bool {
        guard let end = Timestamp.date(before) else { return false }
        let start = after.flatMap(Timestamp.date) ?? .distantPast
        return events.contains { event in
            guard event.actor == "owner", answerKinds.contains(event.kind),
                  let at = Timestamp.date(event.at) else { return false }
            return at > start && at <= end
        }
    }
}
