import Foundation

/// Pond's shared progress log (1.5): stable step ids, folded against the verified
/// accepted body. Requirements are independent of whether a tick exists.
public enum SharedProgress {
    public static func fold(detail: AskDetail) throws -> Set<String> {
        guard !detail.item.revisionMetadataMalformed, !detail.revisionsMetadataMalformed,
              detail.item.revision != nil || detail.revisions.isEmpty else { throw HistoryProblem.missing }
        var bodies: [Int: JSONValue] = [:]
        let accepted: JSONValue
        if let verification = RevisionCheck.verify(detail) {
            let history = try verification.get()
            for revision in detail.revisions {
                bodies[revision.rev] = try JSONValue.parse(Data(revision.body.utf8))
            }
            guard let body = bodies[history.acceptedOnPond] else { throw HistoryProblem.missing }
            accepted = body
        } else {
            guard let body = detail.item.payload.instructableJSON else { return [] }
            accepted = body
        }
        let now = stepIdentities(in: accepted)
        var ticked: Set<String> = []
        for event in detail.events.sorted(by: { $0.seq < $1.seq }) {
            guard event.itemId == detail.item.id, event.kind == "progress", event.actor == "owner",
                  let text = event.text, let delta = try? JSONValue.parse(Data(text.utf8)),
                  case .object = delta, let tick = ids(delta["tick"]), let untick = ids(delta["untick"]) else { continue }
            guard let body = bodies.isEmpty ? accepted : bodies[event.rev ?? 1] else { continue }
            let then = stepIdentities(in: body)
            for id in tick where now[id] != nil && now[id] == then[id] { ticked.insert(id) }
            ticked.subtract(untick)
        }
        return ticked
    }

    private static func ids(_ value: JSONValue?) -> [String]? {
        guard let value, value != .null else { return [] }
        guard case .array(let values) = value else { return nil }
        let strings = values.compactMap(\.stringValue)
        return strings.count == values.count ? strings : nil
    }

    /// Reserved progress identities contain @, which the real step-id grammar
    /// forbids. Verify and pre-id steps therefore cannot alias a real step id.
    public static let verifyID = "@verify"
    public static func legacyID(path: String) -> String { "@legacy:" + path }
    public static func id(for node: DetailModel.Node) -> String {
        node.isVerify ? verifyID : node.stepID ?? legacyID(path: node.path)
    }

    /// Preserve every own field, including fields a newer Pond knows but this Hook
    /// doesn't render. Only id, substeps and required are excluded for real steps.
    /// Legacy nodes use their path plus exact content; Verify uses its complete body.
    public static func stepIdentities(in body: JSONValue) -> [String: JSONValue] {
        var found: [String: JSONValue] = [:]
        func add(_ entry: JSONValue, path: String) {
            guard case .object(var fields) = entry else { return }
            let id = entry["id"]?.stringValue ?? legacyID(path: path)
            for key in ["id", "substeps", "required"] { fields[key] = nil }
            found[id] = .object(fields)
        }
        if case .array(let tops)? = body["steps"] {
            for (index, top) in tops.enumerated() {
                let path = String(index + 1)
                add(top, path: path)
                if case .array(let subs)? = top["substeps"] {
                    for (child, sub) in subs.enumerated() { add(sub, path: path + "." + String(child + 1)) }
                }
            }
        }
        if case .object? = body["verify"] { found[verifyID] = body["verify"] }
        return found
    }
}
