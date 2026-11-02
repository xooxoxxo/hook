import Foundation

/// The owner's current answer at one step path: the latest `answer` event by the owner.
public struct Answer: Sendable, Equatable {
    /// "3" or "3.2".
    public var step: String
    /// The picks of a choice question, in the order of its choices; nil for free text.
    public var picked: [String]?
    /// A free-text answer; nil for a choice question.
    public var text: String?
    public var at: String
    public var seq: Int
    /// The step's id (Pond 1.1.0): sent with the answer, or mapped from `step` through the
    /// revision it was given to; nil for an ask without ids.
    public var id: String?
    /// The revision the answer was bound to; nil when the event names none (rev 1).
    public var rev: Int?

    public init(step: String, picked: [String]? = nil, text: String? = nil, at: String, seq: Int,
                id: String? = nil, rev: Int? = nil) {
        self.step = step; self.picked = picked; self.text = text; self.at = at; self.seq = seq
        self.id = id; self.rev = rev
    }
}

/// Owner answers to the questions on an instructable's steps: a Swift copy of the
/// reference mailbox implementation, held to the same vectors (Fixtures/answers-vectors.json).
/// Each answer `validate` accepts becomes one `answer` event (actor `owner`) whose text
/// is the compact JSON it returns. Errors name the field and never echo a value.
public enum Answers {
    public static let maxAnswers = 20
    public static let maxText = 1000
    static let answerKeys: Set<String> = ["step", "picked", "text"]

    /// One answer of a batch, as `QueueSource.answer` sends it: `{"step","picked"}`.
    public static func entry(step: String, picked: [String]) -> JSONValue {
        .object(["step": .string(step), "picked": .array(picked.map(JSONValue.string))])
    }

    /// One free-text answer of a batch: `{"step","text"}`.
    public static func entry(step: String, text: String) -> JSONValue {
        .object(["step": .string(step), "text": .string(text)])
    }

    /// Every question of a stored instructable by step path, in document order: a
    /// parent's own question comes before those of its sub-steps. Non-object
    /// questions are skipped, as in the reference.
    public static func questions(_ instructable: JSONValue?) -> [(path: String, question: [String: JSONValue])] {
        guard case .array(let steps)? = instructable?["steps"] else { return [] }
        var found: [(path: String, question: [String: JSONValue])] = []
        for (i, step) in steps.enumerated() {
            guard case .object(let members) = step else { continue }
            if case .object(let question)? = members["question"] {
                found.append(("\(i + 1)", question))
            }
            guard case .array(let subs)? = members["substeps"] else { continue }
            for (j, sub) in subs.enumerated() {
                if case .object(let question)? = sub["question"] {
                    found.append(("\(i + 1).\(j + 1)", question))
                }
            }
        }
        return found
    }

    /// The paths of `questions` in a typed instructable, in document order.
    public static func paths(_ instructable: Instructable?) -> [String] {
        guard let instructable else { return [] }
        var paths: [String] = []
        for (i, step) in instructable.steps.enumerated() {
            if step.question != nil { paths.append("\(i + 1)") }
            for (j, sub) in (step.substeps ?? []).enumerated() where sub.question != nil {
                paths.append("\(i + 1).\(j + 1)")
            }
        }
        return paths
    }

    /// `validate_answers`: `.success` holds one event text per answer, in batch order;
    /// `.failure` the errors ("<field path>: <problem>"), and then nothing may be stored.
    /// An event text is compact JSON with `step` first: {"step":"3.2","picked":["Staging"]}
    /// or {"step":"4","text":"…"}.
    public static func validate(_ instructable: JSONValue?, _ answers: JSONValue) -> Result<[String], ValidationFailure> {
        guard case .array(let batch) = answers, (1...maxAnswers).contains(batch.count) else {
            return .failure(ValidationFailure(errors: ["answers: must be a list of 1 to \(maxAnswers) answers"]))
        }
        let asked = Dictionary(questions(instructable).map { ($0.path, $0.question) }) { first, _ in first }
        var errors: [String] = []
        var texts: [String] = []
        var seen = Set<String>()
        for (i, value) in batch.enumerated() {
            let path = "answers[\(i)]"
            guard let answer = Validator.keys(&errors, path, value, allowed: answerKeys) else { continue }
            guard let stepValue = Validator.present(answer["step"]) else {
                errors.append("\(path).step: required")
                continue
            }
            guard case .string(let step) = stepValue else {
                errors.append("\(path).step: must be a string")
                continue
            }
            guard isPath(step), let question = asked[step] else {
                errors.append("\(path).step: no question at this step")
                continue
            }
            guard seen.insert(step).inserted else {
                errors.append("\(path).step: answered twice")
                continue
            }
            if case .array(let choices)? = question["choices"], !choices.isEmpty {
                if Validator.present(answer["text"]) != nil {
                    errors.append("\(path).text: this question takes picks")
                    continue
                }
                guard let picks = picked(&errors, path, choices: choices, multi: question["multi"] == .bool(true),
                                         answer["picked"]) else { continue }
                texts.append("{\"step\":\(jsonString(step)),\"picked\":[\(picks.map(jsonString).joined(separator: ","))]}")
            } else {
                if Validator.present(answer["picked"]) != nil {
                    errors.append("\(path).picked: this question takes text")
                    continue
                }
                let before = errors.count
                Validator.text(&errors, "\(path).text", answer["text"], limit: maxText, required: true, kind: .multi)
                guard errors.count == before, case .string(let text)? = answer["text"] else { continue }
                if Validator.looksSecret(text) {
                    errors.append("\(path).text: secret-like value")
                    continue
                }
                texts.append("{\"step\":\(jsonString(step)),\"text\":\(jsonString(text))}")
            }
        }
        return errors.isEmpty ? .success(texts) : .failure(ValidationFailure(errors: errors))
    }

    /// `latest`: the owner's current answer per step path, where the latest `answer`
    /// event (by seq) wins. Events by others or with an unreadable text are skipped.
    public static func latest(_ events: [Event]) -> [String: Answer] {
        var current: [String: Answer] = [:]
        let ordered = events.enumerated().sorted { ($0.element.seq, $0.offset) < ($1.element.seq, $1.offset) }
        for (_, event) in ordered where event.kind == "answer" && event.actor == "owner" {
            guard let text = event.text, let body = try? JSONValue.parse(Data(text.utf8)),
                  case .string(let step)? = body["step"] else { continue }
            var picked: [String]?
            if case .array(let picks)? = body["picked"] { picked = picks.compactMap(\.stringValue) }
            current[step] = Answer(step: step, picked: picked, text: body["text"]?.stringValue, at: event.at, seq: event.seq)
        }
        return current
    }

    /// The owner's answers by step id, split into (counted, earlier), as the Pond's
    /// `answers.current`: the latest `answer` event per id decides, and it counts only when the
    /// question at that id in the version in force is the one it was given to (the question in
    /// the revision at the event's `rev`); otherwise it is earlier. An event without a rev counts
    /// as rev 1, and one without an id is mapped from its path through that revision (the
    /// version in force when the history lacks it). Held to the `answerRule` vectors.
    public static func current(events: [Event], bodies: [Int: Instructable], inForce: Instructable)
        -> (counted: [String: Answer], earlier: [String: Answer]) {
        var latest: [String: (answer: Answer, valid: Bool)] = [:]
        let ordered = events.enumerated().sorted { ($0.element.seq, $0.offset) < ($1.element.seq, $1.offset) }
        for (_, event) in ordered where event.kind == "answer" && event.actor == "owner" {
            guard let text = event.text, let body = try? JSONValue.parse(Data(text.utf8)), case .object = body else {
                continue
            }
            let version = bodies[event.rev ?? 1] ?? inForce
            let stepID: String
            if case .string(let given)? = body["id"] {
                stepID = given
            } else if case .string(let path)? = body["step"],
                      let mapped = StepIdentity.paths(version).first(where: { $0.value == path })?.key {
                stepID = mapped
            } else {
                continue
            }
            let asked = StepIdentity.question(version, id: stepID)
            let valid = asked != nil && asked == StepIdentity.question(inForce, id: stepID)
            var picked: [String]?
            if case .array(let picks)? = body["picked"] { picked = picks.compactMap(\.stringValue) }
            let answer = Answer(step: body["step"]?.stringValue ?? "", picked: picked, text: body["text"]?.stringValue,
                                at: event.at, seq: event.seq, id: stepID, rev: event.rev)
            latest[stepID] = (answer, valid)
        }
        return (latest.filter(\.value.valid).mapValues(\.answer), latest.filter { !$0.value.valid }.mapValues(\.answer))
    }

    /// What the detail shows, keyed by path in the rendered tree: for an ask whose steps all
    /// carry ids, `current` with the rendered body in force (an earlier answer whose step is gone
    /// has no path and is left out); otherwise `latest`, all counted.
    public static func current(events: [Event], history: VerifiedHistory?, rendered: Instructable?)
        -> (counted: [String: Answer], earlier: [String: Answer]) {
        guard let rendered, StepIdentity.hasIDs(rendered) else { return (latest(events), [:]) }
        let byID = current(events: events, bodies: history?.bodies ?? [:], inForce: rendered)
        let paths = StepIdentity.paths(rendered)
        func byPath(_ answers: [String: Answer]) -> [String: Answer] {
            var out: [String: Answer] = [:]
            for (id, answer) in answers { if let path = paths[id] { out[path] = answer } }
            return out
        }
        return (byPath(byID.counted), byPath(byID.earlier))
    }

    /// "3" or "3.2": 1-based, at most two digits each, no leading zeros (R1).
    public static func isPath(_ text: String) -> Bool {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count) else { return false }
        return parts.allSatisfy { part in
            let scalars = Array(part.unicodeScalars)
            guard (1...2).contains(scalars.count), ("1"..."9").contains(scalars[0]) else { return false }
            return scalars.dropFirst().allSatisfy { ("0"..."9").contains($0) }
        }
    }

    /// `_picked`: the picks of a choice question in the order of its choices, or nil
    /// after recording the errors.
    private static func picked(
        _ errors: inout [String], _ path: String, choices: [JSONValue], multi: Bool, _ value: JSONValue?
    ) -> [String]? {
        guard let value = Validator.present(value) else {
            errors.append("\(path).picked: required")
            return nil
        }
        guard case .array(let picks) = value, !picks.isEmpty, multi || picks.count == 1 else {
            errors.append("\(path).picked: must list " + (multi ? "1 or more of the choices" : "exactly 1 choice"))
            return nil
        }
        // Python compares strings by code point, not by canonical equivalence.
        let options = choices.compactMap(\.stringValue).map { Array($0.unicodeScalars) }
        var ok = true
        var earlier: [[Unicode.Scalar]] = []
        for (k, pick) in picks.enumerated() {
            guard case .string(let string) = pick, options.contains(Array(string.unicodeScalars)) else {
                errors.append("\(path).picked[\(k)]: not one of the choices")
                ok = false
                earlier.append([])
                continue
            }
            let scalars = Array(string.unicodeScalars)
            if earlier.contains(scalars) {
                errors.append("\(path).picked[\(k)]: picked twice")
                ok = false
            }
            earlier.append(scalars)
        }
        guard ok else { return nil }
        let chosen = Set(earlier.map { $0.map(\.value) })
        return options.filter { chosen.contains($0.map(\.value)) }.map { String(String.UnicodeScalarView($0)) }
    }

    /// A JSON string literal as Python's `json.dumps(ensure_ascii=False)` writes it.
    static func jsonString(_ text: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: text, options: [.fragmentsAllowed, .withoutEscapingSlashes]))
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
    }
}
