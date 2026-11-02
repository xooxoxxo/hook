import CryptoKit
import Foundation

/// A step's stable id and its content hash (Pond 1.1.0). Ticks key on the id and keep only
/// while the content hash matches, so a correction that moves a step keeps its tick and one
/// that changes any of its fields drops it.
public enum StepIdentity {
    /// The first 16 hex characters of SHA-256 over `kind US (parentID ?? "") US` + the step's
    /// sorted-keys JSON without `id` and `substeps`: every field the owner sees counts.
    public static func contentHash(_ step: Step, parentID: String?, kind: StepFingerprint.Kind) -> String {
        var own = step
        own.id = nil
        own.substeps = nil
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let json = (try? encoder.encode(own)) ?? Data()
        var input = Data((kind.rawValue + "\u{1F}" + (parentID ?? "") + "\u{1F}").utf8)
        input.append(json)
        return String(SHA256.hash(data: input).map { String(format: "%02x", $0) }.joined().prefix(16))
    }

    /// Every step and sub-step in document order, with its display path ("3", "3.2").
    public static func entries(_ ins: Instructable) -> [(path: String, step: Step)] {
        var found: [(path: String, step: Step)] = []
        for (i, step) in ins.steps.enumerated() {
            found.append(("\(i + 1)", step))
            for (j, sub) in (step.substeps ?? []).enumerated() { found.append(("\(i + 1).\(j + 1)", sub)) }
        }
        return found
    }

    /// Step id → display path, for the steps that carry an id.
    public static func paths(_ ins: Instructable) -> [String: String] {
        var paths: [String: String] = [:]
        for entry in entries(ins) {
            if let id = entry.step.id, paths[id] == nil { paths[id] = entry.path }
        }
        return paths
    }

    /// Every step and sub-step has an id: the ask was posted to Pond 1.1.0 or later.
    public static func hasIDs(_ ins: Instructable?) -> Bool {
        guard let ins, !ins.steps.isEmpty else { return false }
        return entries(ins).allSatisfy { $0.step.id != nil }
    }

    /// The question of the step with this id, or nil.
    public static func question(_ ins: Instructable, id: String) -> Question? {
        entries(ins).first { $0.step.id == id }?.step.question
    }
}

/// The chip a step shows after the owner accepted a correction, until ticked.
public enum StepChip: Equatable, Sendable {
    case changed, new
}
