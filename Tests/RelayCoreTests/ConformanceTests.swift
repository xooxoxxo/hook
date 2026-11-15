import Foundation
import Testing
@testable import RelayCore

/// The shared vectors in `conformance/data/` (conformance/README.md), read straight from the
/// repo by a path relative to this file, not from the Fixtures bundle.
///
/// Six files hold behaviour the Swift core is the reference for: pairing, the review gate, the
/// step flow, Look closer, update stubs and display text. Their inputs are written by hand; their
/// expectations are what the Swift core answers. `HOOK_CONFORMANCE_RECORD=1 swift test --filter
/// ConformanceTests` writes those answers into the files; without it the tests compare and fail
/// on any difference. Three files are recorded from the Pond (history, progress, strict JSON):
/// they are only ever compared, never recorded.
private enum Conformance {
    static let folder = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("conformance/data")

    static let recording = ProcessInfo.processInfo.environment["HOOK_CONFORMANCE_RECORD"] == "1"

    static func root(_ file: String) -> JSONValue? {
        try? JSONValue.parse(Data(contentsOf: folder.appendingPathComponent(file)))
    }

    static func cases(_ file: String) -> [JSONValue] {
        guard case .array(let cases)? = root(file)?["cases"] else { return [] }
        return cases
    }

    /// Case names, the test arguments. A file that can't be read gives none, and
    /// `everyFileHasItsCases` fails.
    static func names(_ file: String) -> [String] {
        cases(file).compactMap { $0["name"]?.stringValue }
    }

    static func named(_ file: String, _ name: String) throws -> JSONValue {
        try #require(cases(file).first { $0["name"]?.stringValue == name }, "\(file): no case \(name)")
    }

    /// A case that names `clients` runs only on those clients; Swift is never one of them yet.
    static func runsHere(_ item: JSONValue) -> Bool { item["clients"] == nil }
}

// MARK: - Ordered output

/// A result in a fixed key order, so a recorded file is byte-identical run after run.
private indirect enum Out {
    case object([(String, Out)])
    case array([Out])
    case string(String)
    case int(Int)
    case bool(Bool)
    case null

    static func text(_ value: String?) -> Out { value.map(Out.string) ?? .null }
    static func strings(_ values: [String]) -> Out { .array(values.map(Out.string)) }

    var json: JSONValue {
        switch self {
        case .object(let members):
            return .object(Dictionary(members.map { ($0.0, $0.1.json) }) { first, _ in first })
        case .array(let items): return .array(items.map(\.json))
        case .string(let text): return .string(text)
        case .int(let number): return .int(number)
        case .bool(let flag): return .bool(flag)
        case .null: return .null
        }
    }

    var ordered: OrderedJSON {
        switch self {
        case .object(let members):
            return .object(members.map { OrderedJSON.Member(key: Out.token($0.0), value: $0.1.ordered) })
        case .array(let items): return .array(items.map(\.ordered))
        case .string(let text): return .scalar(Out.token(text))
        case .int(let number): return .scalar(String(number))
        case .bool(let flag): return .scalar(flag ? "true" : "false")
        case .null: return .scalar("null")
        }
    }

    /// A JSON string token: `/` and non-ASCII as they are; every hidden character (as code
    /// sees them), every control character and every space other than U+0020 (such as the
    /// U+202F in a counter) as a `\u` escape, so the file shows what it holds.
    static func token(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            case "\r": out += "\\r"
            default:
                if scalar.value < 0x20 || Sanitize.isHidden(scalar, as: .code)
                    || (scalar.properties.generalCategory == .spaceSeparator && scalar != " ") {
                    if scalar.value > 0xFFFF {
                        let v = scalar.value - 0x10000
                        out += String(format: "\\u%04X\\u%04X", 0xD800 + (v >> 10), 0xDC00 + (v & 0x3FF))
                    } else {
                        out += String(format: "\\u%04X", scalar.value)
                    }
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }
}

// MARK: - Recording

/// Rewrites one file: every case's output fields set from `fill`, the hand-written key order
/// kept, every string token as `Out.token` writes it, two-space indent, a container on one line
/// when it fits in `width` columns (the file and its `cases` list always open up), one trailing
/// newline.
private enum Recorder {
    static let width = 100

    static func record(_ file: String, _ fill: (_ item: JSONValue, _ root: JSONValue) throws -> [(String, Out)]?) throws {
        let url = Conformance.folder.appendingPathComponent(file)
        let data = try Data(contentsOf: url)
        let parsed = try JSONValue.parse(data)
        guard case .object(var members) = try OrderedJSON.parse(data),
              let index = members.firstIndex(where: { OrderedJSON.keyText($0.key) == "cases" }),
              case .array(var cases) = members[index].value else {
            Issue.record("\(file): no cases to record")
            return
        }
        for position in cases.indices {
            let item = try JSONValue.parse(Data(inline(cases[position]).utf8))
            // A case for other clients keeps its hand-written expectation.
            guard Conformance.runsHere(item), let fields = try fill(item, parsed) else { continue }
            for (key, value) in fields { cases[position].setMember(key, value.ordered) }
        }
        members[index].value = .array(cases)
        try Data((render(canonical(.object(members)), depth: 0, used: 0) + "\n").utf8).write(to: url)
    }

    /// Every string token, hand-written ones included, rewritten by `Out.token`: the same text,
    /// with hidden characters always as `\u` escapes and nothing else escaped that needn't be.
    static func canonical(_ value: OrderedJSON) -> OrderedJSON {
        switch value {
        case .scalar(let raw):
            guard raw.hasPrefix("\""), let text = OrderedJSON.keyText(raw) else { return value }
            return .scalar(Out.token(text))
        case .array(let items):
            return .array(items.map(canonical))
        case .object(let members):
            return .object(members.map {
                OrderedJSON.Member(key: OrderedJSON.keyText($0.key).map(Out.token) ?? $0.key, value: canonical($0.value))
            })
        }
    }

    static func inline(_ value: OrderedJSON) -> String {
        switch value {
        case .scalar(let raw): return raw
        case .array(let items):
            return items.isEmpty ? "[]" : "[" + items.map(inline).joined(separator: ", ") + "]"
        case .object(let members):
            return members.isEmpty ? "{}" : "{" + members.map { $0.key + ": " + inline($0.value) }.joined(separator: ", ") + "}"
        }
    }

    static func render(_ value: OrderedJSON, depth: Int, used: Int) -> String {
        let flat = inline(value)
        if case .scalar = value { return flat }
        if depth >= 2, used + flat.count <= width { return flat }
        let pad = String(repeating: "  ", count: depth + 1), end = String(repeating: "  ", count: depth)
        switch value {
        case .scalar(let raw):
            return raw
        case .array(let items):
            guard !items.isEmpty else { return "[]" }
            return "[\n" + items.map { pad + render($0, depth: depth + 1, used: pad.count) }.joined(separator: ",\n")
                + "\n" + end + "]"
        case .object(let members):
            guard !members.isEmpty else { return "{}" }
            return "{\n" + members.map {
                pad + $0.key + ": " + render($0.value, depth: depth + 1, used: pad.count + $0.key.count + 2)
            }.joined(separator: ",\n") + "\n" + end + "}"
        }
    }
}

// MARK: - Helpers

private let askID = "00000000-0000-4000-8000-000000000001"
private let time = "2026-11-03T09:00:00+00:00"

private func decode<T: Decodable>(_ type: T.Type, _ value: JSONValue?) throws -> T {
    try JSONDecoder().decode(type, from: try #require(value, "missing \(type)").data())
}

private func int(_ value: JSONValue?) -> Int? {
    if case .int(let number)? = value { return number }
    return nil
}

private func strings(_ value: JSONValue?) -> [String] {
    guard case .array(let items)? = value else { return [] }
    return items.compactMap(\.stringValue)
}

private func stamp(_ value: JSONValue?) throws -> RevisionStamp? {
    guard let value, value != .null else { return nil }
    return RevisionStamp(rev: try #require(int(value["rev"])), hash: try #require(value["hash"]?.stringValue))
}

private func hashes(_ value: JSONValue?) throws -> [Int: String] {
    guard case .object(let members)? = value else { return [:] }
    var out: [Int: String] = [:]
    for (key, hash) in members { out[try #require(Int(key))] = try #require(hash.stringValue) }
    return out
}

/// The wire names of history-vectors.json.
private func wire(_ problem: HistoryProblem) -> String {
    switch problem {
    case .badHash(let rev): return "badHash:\(rev)"
    case .badChain(let rev): return "badChain:\(rev)"
    case .unreadable(let rev): return "unreadable:\(rev)"
    case .rolledBack: return "rolledBack"
    case .missing: return "missing"
    case .fixedFieldChanged(let rev): return "fixedFieldChanged:\(rev)"
    }
}

private func problem(_ text: String) throws -> HistoryProblem {
    let parts = text.split(separator: ":", maxSplits: 1).map(String.init)
    let rev = parts.count == 2 ? Int(parts[1]) : nil
    switch (parts[0], rev) {
    case ("badHash", let rev?): return .badHash(rev)
    case ("badChain", let rev?): return .badChain(rev)
    case ("unreadable", let rev?): return .unreadable(rev)
    case ("fixedFieldChanged", let rev?): return .fixedFieldChanged(rev)
    case ("rolledBack", nil): return .rolledBack
    case ("missing", nil): return .missing
    default: throw ConformanceError.unknownProblem(text)
    }
}

private enum ConformanceError: Error {
    case unknownProblem(String)
    case unknownKind(String)
}

// MARK: - The six Swift-referenced files

private enum Reference {
    // pairing-vectors.json: PhonePairing.decode.

    static let padPrefix = #"{"v":1,"url":"https://pond.example.test","token":"synthetic-token-for-tests","context":""#
    static let padSuffix = #""}"#

    static func padded(_ bytes: Int) -> Data {
        let fill = bytes - padPrefix.utf8.count - padSuffix.utf8.count
        return Data((padPrefix + String(repeating: "x", count: max(fill, 0)) + padSuffix).utf8)
    }

    static func pairing(_ item: JSONValue, _ root: JSONValue) throws -> [(String, Out)]? {
        let padded = int(item["pad"]?["bytes"]).map(padded)
        let data: Data
        if let padded { data = padded } else { data = Data(try #require(item["payload"]?.stringValue).utf8) }
        let result: Out
        do {
            let pairing = try PhonePairing.decode(data)
            var fields: [(String, Out)] = [("ok", .bool(true)), ("url", .string(pairing.url.absoluteString))]
            if padded == nil { fields += [("context", .string(pairing.context)), ("sourceKey", .string(pairing.sourceKey))] }
            result = .object(fields)
        } catch let failure as PhonePairing.Failure {
            result = .object([("ok", .bool(false)), ("failure", .string("\(failure)"))])
        }
        return [("expect", result)]
    }

    // reviewgate-vectors.json: ReviewGate.resolve.

    static func reviewGate(_ item: JSONValue, _ root: JSONValue) throws -> [(String, Out)]? {
        func body(_ name: JSONValue?) throws -> Instructable? {
            guard let name = name?.stringValue else { return nil }
            return try decode(Instructable.self, root[name])
        }
        var record: ReviewRecord?
        if let raw = item["record"], raw != .null {
            record = ReviewRecord(accepted: try stamp(raw["accepted"]), seen: try stamp(raw["seen"]),
                                  pins: try hashes(raw["pins"]),
                                  firstBodyHash: try body(raw["firstBody"]).map(ReviewGate.bodyHash))
        }
        let spec = try #require(item["history"])
        let history: Result<VerifiedHistory, HistoryProblem>?
        switch spec["kind"]?.stringValue {
        case "none":
            history = nil
        case "problem":
            history = .failure(try problem(try #require(spec["problem"]?.stringValue)))
        case "ok":
            let first = try #require(try body(.string("first")))
            let stamps = try hashes(spec["stamps"]).reduce(into: [Int: RevisionStamp]()) {
                $0[$1.key] = RevisionStamp(rev: $1.key, hash: $1.value)
            }
            let currentRev = try #require(int(spec["current"]))
            let current = try #require(stamps[currentRev])
            history = .success(VerifiedHistory(
                bodies: stamps.mapValues { _ in first }, stamps: stamps, current: current,
                acceptedOnPond: try #require(int(spec["acceptedOnPond"])), reasons: [:]))
        default:
            throw ConformanceError.unknownKind(spec["kind"]?.stringValue ?? "")
        }
        var pond: PondVersion?
        if let text = item["pond"]?.stringValue {
            if text.hasPrefix("protocol ") {
                pond = .legacy(protocol: try #require(Int(text.dropFirst("protocol ".count))))
            } else {
                pond = .semver(try #require(SemVer(strict: text)))
            }
        }
        let state = ReviewGate.resolve(record: record, history: history, pond: pond, served: try body(item["served"]))
        var fields: [(String, Out)]
        switch state {
        case .legacy: fields = [("state", .string("legacy"))]
        case .current: fields = [("state", .string("current"))]
        case .pending(let shown, _, _): fields = [("state", .string("pending")), ("shown", shown.map { .int($0.rev) } ?? .null)]
        case .historyChanged(let problem): fields = [("state", .string("historyChanged")), ("problem", .string(wire(problem)))]
        case .waitingForKeychain: fields = [("state", .string("waitingForKeychain"))]
        }
        fields.insert(("locked", .bool(state.isLocked)), at: 1)
        switch state.action {
        case .review?: fields.append(("action", .string("review")))
        case .trustHistory?: fields.append(("action", .string("trustHistory")))
        case nil: fields.append(("action", .null))
        }
        return [("expect", .object(fields))]
    }

    // flow-vectors.json: DetailModel, Flow, Requirements, SharedProgress.id.

    static func flow(_ item: JSONValue, _ root: JSONValue) throws -> [(String, Out)]? {
        let ins = try decode(Instructable.self, item["instructable"])
        let wireItem = WireItem(id: askID, title: ins.title, status: "open", created: time, updated: time,
                                payload: Payload(instructable: ins))
        guard case .array(let rawEvents)? = item["events"] else { throw ConformanceError.unknownKind("events") }
        let events = try rawEvents.map { event in
            Event(seq: try #require(int(event["seq"])), itemId: askID, kind: try #require(event["kind"]?.stringValue),
                  actor: try #require(event["actor"]?.stringValue), text: event["text"]?.stringValue, at: time,
                  rev: int(event["rev"]))
        }
        let model = DetailModel.make(item: wireItem, events: events)
        let ticks = Set(strings(item["ticks"]))
        let nodes = model.nodes
        let progress = Flow.progress(ticks: ticks, nodes: nodes)
        let requirements = Requirements.state(model, ticks: ticks)
        let left: [Out] = requirements.left.map { entry in
            switch entry {
            case .step(let path, _): return .object([("kind", .string("step")), ("path", .string(path))])
            case .reply: return .object([("kind", .string("reply"))])
            case .message: return .object([("kind", .string("message"))])
            }
        }
        var fields: [(String, Out)] = [
            ("current", .text(Flow.currentStep(ticks: ticks, nodes: nodes))),
            ("done", .int(progress.done)), ("total", .int(progress.total)),
            ("tickable", .strings(Flow.tickable(nodes).map(\.path))),
            ("locked", .strings(Flow.lockedPaths(nodes: nodes, ticks: ticks))),
            ("left", .array(left)), ("ready", .bool(requirements.ready)),
        ]
        if let delta = item["expect"]?["delta"] {
            let before = strings(delta["before"]), after = strings(delta["after"])
            let sent = Requirements.delta(nodes: nodes, before: Set(before), after: Set(after), shared: true)
            fields.append(("delta", .object([("before", .strings(before)), ("after", .strings(after)),
                                            ("tick", .strings(sent.tick)), ("untick", .strings(sent.untick))])))
        }
        return [("expect", .object(fields))]
    }

    // lookcloser-vectors.json: LookCloser.flags.

    static func lookCloser(_ item: JSONValue, _ root: JSONValue) throws -> [(String, Out)]? {
        let old = try item["old"].map { try decode(Instructable.self, $0) }
        let new = try decode(Instructable.self, item["new"])
        let flags = LookCloser.flags(old: old, new: new, cwd: item["cwd"]?.stringValue)
        return [("flags", .array(flags.map {
            .object([("kind", .string($0.kind.rawValue)), ("location", .string($0.location)), ("text", .string($0.text))])
        }))]
    }

    // stub-vectors.json: the Pond's update stub, pondStub cases only.

    /// The Pond's stub text (kind `stub` of revision-vectors.json). The Swift core has no stub
    /// recogniser: an old Hook shows the stub as an ordinary ask, which is what it is for.
    static let stubWhy = "This ask was corrected after it was posted. Update Hook to see the corrected steps; don't press Done here."
    static let stubStep = "Update Hook: menu bar › Check for Updates…"

    /// The exact why and a single step doing exactly the stub's step.
    static func isPondStub(_ ins: JSONValue) -> Bool {
        guard ins["why"]?.stringValue == stubWhy, case .array(let steps)? = ins["steps"], steps.count == 1 else { return false }
        return steps[0]["do"]?.stringValue == stubStep
    }

    static func stub(_ item: JSONValue, _ root: JSONValue) throws -> [(String, Out)]? {
        let ins = try #require(item["instructable"])
        let result: Out = isPondStub(ins)
            ? .object([("stub", .bool(true)), ("reason", .string("pondStub"))])
            : .object([("stub", .bool(false))])
        return [("expect", result)]
    }

    // display-vectors.json: Sanitize, LinkDisplay, ReplyText, TalkLimits, RelayURL, SourceKey.

    static func display(_ item: JSONValue, _ root: JSONValue) throws -> [(String, Out)]? {
        func text(_ key: String) throws -> String { try #require(item[key]?.stringValue, "\(key)") }
        func number(_ key: String) throws -> Int { try #require(int(item[key]), "\(key)") }
        let kind = try text("kind")
        switch kind {
        case "reveal":
            let cls: FieldClass = item["code"] == .bool(true) ? .code : .prose
            return [("output", .string(Sanitize.reveal(try text("input"), as: cls).text))]
        case "revealLine":
            return [("output", .string(Sanitize.revealLine(try text("input"))))]
        case "copyText":
            return [("output", .string(Sanitize.copyText(try text("input"))))]
        case "linkTitle":
            return [("output", .string(LinkDisplay.linkTitle(label: try text("label"), url: try text("url"))))]
        case "stepTitle":
            return [("output", .text(LinkDisplay.stepTitle(try text("url"))))]
        case "replyWire":
            return [("output", .string(ReplyText.wire(choice: try text("choice"), words: item["words"]?.stringValue)))]
        case "replyParse":
            let parsed = ReplyText.parse(try text("text"), choices: strings(item["choices"]))
            return [("index", parsed.map { .int($0.index) } ?? .null), ("words", .text(parsed?.words))]
        case "counter":
            let count = try number("count"), limit = try number("limit")
            return [("shows", .bool(TalkLimits.showsCounter(count, limit: limit))),
                    ("text", .string(TalkLimits.counter(count, limit: limit))),
                    ("over", .text(TalkLimits.over(count, limit: limit)))]
        case "deepLink":
            var id: String?
            if let url = URL(string: try text("url")), case .open(let opened)? = RelayURL.parse(url) { id = opened }
            return [("id", .text(id))]
        case "sourceKey":
            let url = try #require(URL(string: try text("url")))
            return [("output", .string(SourceKey.mailbox(MailboxSettings(url: url, tokenFile: "", context: try text("context")))))]
        default:
            throw ConformanceError.unknownKind(kind)
        }
    }

    typealias Fill = @Sendable (JSONValue, JSONValue) throws -> [(String, Out)]?

    static let files: [(file: String, fill: Fill, minimum: Int)] = [
        ("pairing-vectors.json", pairing, 18),
        ("reviewgate-vectors.json", reviewGate, 16),
        ("flow-vectors.json", flow, 20),
        ("lookcloser-vectors.json", lookCloser, 12),
        ("stub-vectors.json", stub, 12),
        ("display-vectors.json", display, 40),
    ]

    static func fill(_ file: String) -> Fill { files.first { $0.file == file }!.fill }
}

/// Compares every output field of one case with what the Swift core answers now.
private func check(_ file: String, _ name: String) throws {
    let item = try Conformance.named(file, name)
    let root = try #require(Conformance.root(file))
    guard Conformance.runsHere(item), let fields = try Reference.fill(file)(item, root) else { return }
    for (key, value) in fields {
        #expect(item[key] == value.json, "\(file) \(name): \(key)")
    }
}

@Suite struct ConformanceTests {
    @Test(.enabled(if: !Conformance.recording), arguments: Conformance.names("pairing-vectors.json"))
    func pairing(_ name: String) throws {
        let item = try Conformance.named("pairing-vectors.json", name)
        if let bytes = int(item["pad"]?["bytes"]) { #expect(Reference.padded(bytes).count == bytes) }
        try check("pairing-vectors.json", name)
    }

    @Test(.enabled(if: !Conformance.recording), arguments: Conformance.names("reviewgate-vectors.json"))
    func reviewGate(_ name: String) throws { try check("reviewgate-vectors.json", name) }

    @Test(.enabled(if: !Conformance.recording), arguments: Conformance.names("flow-vectors.json"))
    func flow(_ name: String) throws { try check("flow-vectors.json", name) }

    @Test(.enabled(if: !Conformance.recording), arguments: Conformance.names("lookcloser-vectors.json"))
    func lookCloser(_ name: String) throws { try check("lookcloser-vectors.json", name) }

    @Test(.enabled(if: !Conformance.recording), arguments: Conformance.names("stub-vectors.json"))
    func stub(_ name: String) throws { try check("stub-vectors.json", name) }

    @Test(.enabled(if: !Conformance.recording), arguments: Conformance.names("display-vectors.json"))
    func display(_ name: String) throws { try check("display-vectors.json", name) }

    /// `HOOK_CONFORMANCE_RECORD=1`: writes the Swift core's answers into the six files.
    @Test(.enabled(if: Conformance.recording)) func record() throws {
        for entry in Reference.files { try Recorder.record(entry.file, entry.fill) }
    }

    @Test func everyFileHasItsCases() {
        for entry in Reference.files {
            let names = Conformance.names(entry.file)
            #expect(names.count >= entry.minimum, "\(entry.file): \(names.count) cases")
            #expect(Set(names).count == names.count, "\(entry.file): a case name repeats")
        }
        let display = Conformance.cases("display-vectors.json")
        for kind in ["reveal", "revealLine", "copyText", "linkTitle", "stepTitle", "replyWire", "replyParse", "counter",
                     "deepLink", "sourceKey"] {
            #expect(display.filter { $0["kind"]?.stringValue == kind }.count >= 3, "display kind \(kind)")
        }
        for file in ["history-vectors.json", "progress-vectors.json", "strictjson-vectors.json"] {
            #expect(!Conformance.names(file).isEmpty, "\(file) has no cases")
        }
    }

    /// The stub recogniser holds the same text the Pond writes.
    @Test func everyPondStubIsRecognised() {
        let stubs = Conformance.cases("revision-vectors.json").filter { $0["kind"]?.stringValue == "stub" }
        #expect(!stubs.isEmpty)
        for item in stubs {
            #expect(Reference.isPondStub(item["output"] ?? .null), "\(item["name"]?.stringValue ?? "")")
        }
    }

    // MARK: Pond-recorded files: compared, never recorded

    /// history-vectors.json: RevisionCheck.verify, then checkPins.
    @Test(arguments: Conformance.names("history-vectors.json"))
    func history(_ name: String) throws {
        let item = try Conformance.named("history-vectors.json", name)
        let detail = try decode(AskDetail.self, item["detail"])
        let actual: JSONValue
        switch RevisionCheck.verify(detail) {
        case nil:
            actual = .object(["ok": .bool(false), "problem": .string("none: verify found no revision")])
        case .failure(let problem)?:
            actual = .object(["ok": .bool(false), "problem": .string(wire(problem))])
        case .success(let history)?:
            if let problem = RevisionCheck.checkPins(history, pins: try hashes(item["pins"])) {
                actual = .object(["ok": .bool(false), "problem": .string(wire(problem))])
            } else {
                actual = .object(["ok": .bool(true), "acceptedOnPond": .int(history.acceptedOnPond),
                                  "current": .object(["rev": .int(history.current.rev),
                                                      "hash": .string(history.current.hash)])])
            }
        }
        #expect(actual == item["expect"], "history-vectors.json \(name)")
    }

    /// progress-vectors.json: SharedProgress.fold, sorted.
    @Test(arguments: Conformance.names("progress-vectors.json"))
    func progress(_ name: String) throws {
        let item = try Conformance.named("progress-vectors.json", name)
        let detail = try decode(AskDetail.self, item["detail"])
        let ticked = try SharedProgress.fold(detail: detail).sorted()
        #expect(ticked == strings(item["ticked"]), "progress-vectors.json \(name)")
    }

    /// strictjson-vectors.json: the strict parse the core uses for revision bodies.
    @Test(arguments: Conformance.names("strictjson-vectors.json"))
    func strictJSON(_ name: String) throws {
        let item = try Conformance.named("strictjson-vectors.json", name)
        let data: Data
        if let hex = item["hex"]?.stringValue {
            var bytes: [UInt8] = []
            var index = hex.startIndex
            while index < hex.endIndex {
                let next = hex.index(index, offsetBy: 2)
                bytes.append(try #require(UInt8(hex[index..<next], radix: 16)))
                index = next
            }
            data = Data(bytes)
        } else {
            data = Data(try #require(item["text"]?.stringValue).utf8)
        }
        let parses = (try? JSONValue.parse(data)) != nil
            && (try? OrderedJSON.parse(data)).map { !OrderedJSON.hasDuplicateKeys($0) } == true
        #expect(parses == (item["parses"] == .bool(true)), "strictjson-vectors.json \(name): parses")

        // A revision body arrives as a JSON string, so it is always UTF-8; bytes that aren't
        // can't reach RevisionBody.parse and are invalid.
        var problem: String?
        if let text = String(data: data, encoding: .utf8) {
            do { _ = try RevisionBody.parse(text) } catch let error as RevisionBodyError {
                problem = error == .duplicateKey ? "duplicateKey" : "invalid"
            }
        } else {
            problem = "invalid"
        }
        #expect((problem == nil) == (item["body"] == .bool(true)), "strictjson-vectors.json \(name): body")
        #expect(problem == item["problem"]?.stringValue, "strictjson-vectors.json \(name): problem")
    }
}
