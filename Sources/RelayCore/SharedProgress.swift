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

    /// Preserve every own field, including fields a newer Pond knows but this Hook
    /// doesn't render. Only id, substeps and required are excluded on the server.
    public static func stepIdentities(in body: JSONValue) -> [String: JSONValue] {
        guard case .array(let tops)? = body["steps"] else { return [:] }
        var found: [String: JSONValue] = [:]
        for top in tops {
            var entries = [top]
            if case .array(let subs)? = top["substeps"] { entries += subs }
            for entry in entries {
                guard let id = entry["id"]?.stringValue, case .object(var fields) = entry else { continue }
                for key in ["id", "substeps", "required"] { fields[key] = nil }
                found[id] = .object(fields)
            }
        }
        return found
    }
}
