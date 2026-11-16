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

/// A revision body exactly as the strict read parsed it: keys in file order and as decoded
/// (never merged by canonical equivalence), strings decoded, numbers as their source text.
/// `AppendCheck` compares these, not `JSONValue`, which turns numbers into Int or Double.
public indirect enum ExactJSON: Sendable, Equatable {
    public struct Member: Sendable {
        public var key: String
        public var value: ExactJSON
        public init(key: String, value: ExactJSON) { self.key = key; self.value = value }
    }

    case object([Member])
    case array([ExactJSON])
    case string(String)
    /// The number's text as written, e.g. "1.0".
    case number(String)
    case bool(Bool)
    case null

    struct Unreadable: Error {}

    /// From the token tree of text `JSONSerialization` already accepted.
    init(_ value: OrderedJSON) throws {
        switch value {
        case .object(let members):
            self = .object(try members.map { member in
                guard let key = OrderedJSON.keyText(member.key) else { throw Unreadable() }
                return Member(key: key, value: try ExactJSON(member.value))
            })
        case .array(let items):
            self = .array(try items.map(ExactJSON.init))
        case .scalar(let raw):
            switch raw {
            case "true": self = .bool(true)
            case "false": self = .bool(false)
            case "null": self = .null
            default:
                if raw.hasPrefix("\"") {
                    guard let text = OrderedJSON.keyText(raw) else { throw Unreadable() }
                    self = .string(text)
                } else {
                    self = .number(raw)
                }
            }
        }
    }

    /// The member whose key has exactly these Unicode scalars.
    public subscript(key: String) -> ExactJSON? {
        guard case .object(let members) = self else { return nil }
        return members.first { AppendCheck.sameScalars($0.key, key) }?.value
    }

    public var stringValue: String? {
        guard case .string(let text) = self else { return nil }
        return text
    }

    public static func == (a: ExactJSON, b: ExactJSON) -> Bool { AppendCheck.same(a, b) }
}

/// Hook's own check that a revision only adds steps at the end (conformance/append-vectors.json).
/// It reads the bodies as served, parsed strictly, and never the Pond's `kind`: the review lock
/// stays Hook's.
public enum AppendCheck {
    /// True when `next.steps` is longer than `base.steps`, every one of `base.steps` is the same
    /// JSON value at the same index of `next.steps` (ids, sub-steps and unknown keys included),
    /// and every other top-level key is in both or neither, with equal values. JSON value
    /// equality ignores key order and white space and is exact (`same`).
    public static func isAppend(base: ExactJSON, next: ExactJSON) -> Bool {
        guard case .object(let old) = base, case .object(let new) = next,
              case .array(let oldSteps)? = base["steps"], case .array(let newSteps)? = next["steps"],
              newSteps.count > oldSteps.count else { return false }
        guard zip(oldSteps, newSteps).allSatisfy({ same($0, $1) }) else { return false }
        let oldRest = old.filter { !sameScalars($0.key, "steps") }, newRest = new.filter { !sameScalars($0.key, "steps") }
        return same(.object(oldRest), .object(newRest))
    }

    /// Exact JSON value equality, as the Pond and Kotlin compare: strings and object keys by
    /// Unicode scalars (Swift's `String ==` would equate "é" and "e\u{301}"), numbers by their
    /// exact source text (`1` and `1.0` differ; nothing goes through Int or Double), a boolean
    /// never equal to a number, objects by key set and values, arrays element by element.
    static func same(_ a: ExactJSON, _ b: ExactJSON) -> Bool {
        switch (a, b) {
        case (.string(let x), .string(let y)): return sameScalars(x, y)
        case (.number(let x), .number(let y)): return x.utf8.elementsEqual(y.utf8)
        case (.bool(let x), .bool(let y)): return x == y
        case (.null, .null): return true
        case (.array(let x), .array(let y)):
            return x.count == y.count && zip(x, y).allSatisfy { same($0, $1) }
        case (.object(let x), .object(let y)):
            // Keys never go through a String-keyed lookup, which merges canonically equivalent
            // keys: both member lists sorted by key scalars, then compared pairwise. The strict
            // read refuses an object whose keys collide, so the order is total.
            guard x.count == y.count else { return false }
            return zip(sortedByKey(x), sortedByKey(y)).allSatisfy { sameScalars($0.key, $1.key) && same($0.value, $1.value) }
        default: return false
        }
    }

    static func sameScalars(_ a: String, _ b: String) -> Bool {
        a.unicodeScalars.elementsEqual(b.unicodeScalars)
    }

    private static func sortedByKey(_ members: [ExactJSON.Member]) -> [ExactJSON.Member] {
        members.sorted { $0.key.unicodeScalars.lexicographicallyPrecedes($1.key.unicodeScalars) { $0.value < $1.value } }
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

    /// The first revision of the run of appends that ends at `rev`: the last revision up to `rev`
    /// that isn't an append of the one before it (or whose bodies are missing), else 1.
    public static func runStart(_ history: VerifiedHistory, through rev: Int) -> Int {
        var start = min(max(rev, 1), history.current.rev)
        while start > 1, let previous = history.raw[start - 1], let body = history.raw[start],
              isAppend(base: previous, next: body) {
            start -= 1
        }
        return start
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
