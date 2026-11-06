import Foundation

/// One run of a word diff.
public enum DiffToken: Equatable, Sendable {
    case same(String), removed(String), added(String)

    public var text: String {
        switch self {
        case .same(let text), .removed(let text), .added(let text): return text
        }
    }
}

/// A word-by-word diff: words, whitespace runs and the shell's punctuation are tokens, so a
/// change inside a long one-line command shows as just the changed words.
public enum WordDiff {
    /// Above this many tokens on either side, the diff goes character by character.
    public static let tokenLimit = 4000
    static let punctuation: Set<Character> = ["/", ":", ".", "|", ";", "&", "=", "\"", "'", "(", ")", "$", "<", ">"]

    public static func tokens(_ old: String, _ new: String) -> [DiffToken] {
        var a = split(old), b = split(new)
        if a.count > tokenLimit || b.count > tokenLimit {
            a = old.map(String.init)
            b = new.map(String.init)
        }
        return merge(ordered(a, b))
    }

    /// Whitespace runs, single punctuation characters, and the runs between them.
    static func split(_ text: String) -> [String] {
        var tokens: [String] = []
        var run = ""
        var runIsSpace = false
        for character in text {
            if punctuation.contains(character) {
                if !run.isEmpty { tokens.append(run) }
                run = ""
                tokens.append(String(character))
                continue
            }
            let space = character.isWhitespace
            if !run.isEmpty, space != runIsSpace {
                tokens.append(run)
                run = ""
            }
            run.append(character)
            runIsSpace = space
        }
        if !run.isEmpty { tokens.append(run) }
        return tokens
    }

    /// The tokens in reading order: removals before the insertions that replace them.
    private static func ordered(_ a: [String], _ b: [String]) -> [DiffToken] {
        let difference = b.difference(from: a)
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        var out: [DiffToken] = []
        var i = 0, j = 0
        while i < a.count || j < b.count {
            if i < a.count, removed.contains(i) {
                out.append(.removed(a[i]))
                i += 1
            } else if j < b.count, inserted.contains(j) {
                out.append(.added(b[j]))
                j += 1
            } else if i < a.count, j < b.count {
                out.append(.same(b[j]))
                i += 1
                j += 1
            } else {
                break
            }
        }
        return out
    }

    /// Neighbouring tokens of one kind become one run.
    private static func merge(_ tokens: [DiffToken]) -> [DiffToken] {
        var out: [DiffToken] = []
        for token in tokens {
            switch (out.last, token) {
            case (.same(let a)?, .same(let b)): out[out.count - 1] = .same(a + b)
            case (.removed(let a)?, .removed(let b)): out[out.count - 1] = .removed(a + b)
            case (.added(let a)?, .added(let b)): out[out.count - 1] = .added(a + b)
            default: out.append(token)
            }
        }
        return out
    }
}

/// One field that differs (or, on a first view, every field present).
public struct FieldDiff: Equatable, Sendable {
    /// "code", "question.choices", "verify.code", "links.2.url", …
    public var name: String
    public var old: String?
    public var new: String?
    public var tokens: [DiffToken]

    public init(name: String, old: String?, new: String?) {
        self.name = name
        self.old = old
        self.new = new
        tokens = WordDiff.tokens(old ?? "", new ?? "")
    }

    /// A command, a link or a file: accepting a change to one needs Touch ID. A `detail`
    /// renders its web links as clickable (`DetailText`), so one that gains a link, or
    /// changes one, counts as a link; a detail that only drops links or changes its words doesn't.
    public var isCommandLinkOrFile: Bool {
        let field = name.split(separator: ".").last.map(String.init) ?? name
        if ["code", "url", "file", "path"].contains(field) { return true }
        guard field == "detail", let new else { return false }
        return !DetailText.webLinks(new).isSubset(of: old.map(DetailText.webLinks) ?? [])
    }
}

/// One step or sub-step that differs, matched by its stable id.
public struct StepChange: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case changed, added, removed, moved }

    public var kind: Kind
    public var stepID: String
    public var oldPath: String?
    public var newPath: String?
    public var fields: [FieldDiff]

    public init(kind: Kind, stepID: String, oldPath: String?, newPath: String?, fields: [FieldDiff]) {
        self.kind = kind; self.stepID = stepID; self.oldPath = oldPath; self.newPath = newPath; self.fields = fields
    }
}

/// One cumulative diff, from this Mac's last accepted (else last seen) revision to the
/// current one; or, when this Mac never showed the ask (`isFirstView`), the full current
/// content with every reason.
public struct RevisionDiff: Equatable, Sendable {
    public var isFirstView: Bool
    public var steps: [StepChange]
    /// why, every verify field, the reply's prompt and choices, `done`, each link's label, url and path.
    public var top: [FieldDiff]
    /// Every reason since the baseline (since rev 1 on a first view), oldest first.
    public var reasons: [(rev: Int, reason: String)]
    /// A command, link or file changed since the baseline (since rev 1 on a first view), so
    /// accepting needs Touch ID.
    public var touchesCommandsLinksOrFiles: Bool
    /// What accepting resets: ticks, answers that become earlier, steps that wait again or unlock.
    public var resets: [String]

    public static func == (a: RevisionDiff, b: RevisionDiff) -> Bool {
        a.isFirstView == b.isFirstView && a.steps == b.steps && a.top == b.top
            && a.reasons.map(\.rev) == b.reasons.map(\.rev) && a.reasons.map(\.reason) == b.reasons.map(\.reason)
            && a.touchesCommandsLinksOrFiles == b.touchesCommandsLinksOrFiles && a.resets == b.resets
    }

    /// The ids accepting marks: changed steps show "Changed", added ones "New".
    public var changedIDs: [String] { steps.filter { $0.kind == .changed }.map(\.stepID) }
    public var addedIDs: [String] { steps.filter { $0.kind == .added }.map(\.stepID) }

    /// While the correction is pending: the tags on the version still shown, by its paths. A
    /// changed step reads "Changed" and a removed one "Removed"; added ones aren't on it. None
    /// on a first view, which has no shown version.
    public var shownChips: [String: StepChip] {
        guard !isFirstView else { return [:] }
        var chips: [String: StepChip] = [:]
        for change in steps {
            guard let path = change.oldPath else { continue }
            switch change.kind {
            case .changed: chips[path] = .changed
            case .removed: chips[path] = .removed
            case .added, .moved: break
            }
        }
        return chips
    }

    public static func make(baseline: Instructable?, firstRevision: Instructable, current: Instructable,
                            reasons: [(rev: Int, reason: String)]) -> RevisionDiff {
        let since = changes(from: baseline ?? firstRevision, to: current)
        let touches = since.steps.contains { $0.kind != .removed && $0.fields.contains(where: \.isCommandLinkOrFile) }
            || since.top.contains { $0.isCommandLinkOrFile && $0.new != nil }
        guard let baseline else {
            let full = changes(from: nil, to: current)
            return RevisionDiff(isFirstView: true, steps: full.steps, top: full.top, reasons: reasons,
                                touchesCommandsLinksOrFiles: touches, resets: [])
        }
        let diff = changes(from: baseline, to: current)
        return RevisionDiff(isFirstView: false, steps: diff.steps, top: diff.top, reasons: reasons,
                            touchesCommandsLinksOrFiles: touches, resets: resets(diff.steps, baseline: baseline,
                                                                                 current: current))
    }

    // MARK: Fields

    /// Every field the owner sees on a step, by name; absent ones are nil.
    static func fields(_ step: Step) -> [(String, String?)] {
        [("do", step.action), ("where", step.place), ("detail", step.detail), ("code", step.code), ("lang", step.lang),
         ("expect", step.expect), ("url", step.url), ("file", step.file), ("warning", step.warning),
         ("blocking", step.blocking == true ? "true" : nil), ("optional", step.optional == true ? "true" : nil),
         ("required", step.required == true ? "true" : nil),
         ("question.prompt", step.question?.prompt),
         ("question.choices", step.question?.choices.map { $0.map(\.diffText).joined(separator: "\n") }),
         ("question.multi", step.question?.multi == true ? "true" : nil)]
    }

    static func fieldDiffs(_ old: [(String, String?)]?, _ new: [(String, String?)], prefix: String = "") -> [FieldDiff] {
        var out: [FieldDiff] = []
        for (index, (name, value)) in new.enumerated() {
            let before = old?[index].1
            if before != value, before != nil || value != nil {
                out.append(FieldDiff(name: prefix + name, old: before, new: value))
            }
        }
        return out
    }

    static func topFields(_ ins: Instructable) -> [(String, String?)] {
        var fields: [(String, String?)] = [("why", ins.why), ("warning", ins.warning)]
        let names = Self.fields(Step(action: "")).map(\.0)
        let values: [String?] = ins.verify.map { Self.fields($0).map(\.1) } ?? Array(repeating: nil, count: names.count)
        fields += zip(names, values).map { ("verify." + $0, $1) }
        fields += [("reply.prompt", ins.reply?.prompt), ("reply.choices", ins.reply?.choices.map { $0.map(\.diffText).joined(separator: "\n") })]
        // The known values only, in the order the ask gives them.
        let done = (ins.done ?? []).filter { DoneRequirement(rawValue: $0) != nil }
        fields.append(("done", done.isEmpty ? nil : done.joined(separator: "\n")))
        return fields
    }

    static func linkFields(_ links: [LinkRef]?, count: Int) -> [(String, String?)] {
        (0..<count).flatMap { i -> [(String, String?)] in
            let link = (links ?? []).indices.contains(i) ? links?[i] : nil
            return [("links.\(i + 1).label", link?.label), ("links.\(i + 1).url", link?.url), ("links.\(i + 1).path", link?.path)]
        }
    }

    // MARK: Steps

    private static func changes(from old: Instructable?, to new: Instructable) -> (steps: [StepChange], top: [FieldDiff]) {
        let before = old.map(StepIdentity.entries) ?? []
        let after = StepIdentity.entries(new)
        let oldByID = Dictionary(before.compactMap { e in e.step.id.map { ($0, e) } }) { first, _ in first }
        let newIDs = Set(after.compactMap(\.step.id))
        let kept = after.compactMap(\.step.id).filter { oldByID[$0] != nil }
        let keptOld = before.compactMap(\.step.id).filter { newIDs.contains($0) }
        let moved = Set(kept.difference(from: keptOld).compactMap { change -> String? in
            if case .insert(_, let id, _) = change { return id }
            return nil
        })
        var steps: [StepChange] = []
        for entry in after {
            let id = entry.step.id ?? entry.path
            guard let previous = oldByID[id] else {
                steps.append(StepChange(kind: .added, stepID: id, oldPath: nil, newPath: entry.path,
                                        fields: fieldDiffs(nil, fields(entry.step))))
                continue
            }
            let diffs = fieldDiffs(fields(previous.step), fields(entry.step))
            if !diffs.isEmpty {
                steps.append(StepChange(kind: .changed, stepID: id, oldPath: previous.path, newPath: entry.path, fields: diffs))
            } else if moved.contains(id) {
                steps.append(StepChange(kind: .moved, stepID: id, oldPath: previous.path, newPath: entry.path, fields: []))
            }
        }
        for entry in before where !newIDs.contains(entry.step.id ?? entry.path) {
            steps.append(StepChange(kind: .removed, stepID: entry.step.id ?? entry.path, oldPath: entry.path, newPath: nil,
                                    fields: fieldDiffs(fields(entry.step), fields(entry.step).map { ($0.0, nil) })))
        }
        let linkCount = max(old?.links?.count ?? 0, new.links?.count ?? 0)
        var top = fieldDiffs(old.map(topFields), topFields(new))
        top += fieldDiffs(old.map { linkFields($0.links, count: linkCount) }, linkFields(new.links, count: linkCount))
        return (steps, top)
    }

    // MARK: Resets

    private static func resets(_ steps: [StepChange], baseline: Instructable, current: Instructable) -> [String] {
        var lines: [String] = []
        let paths = StepIdentity.paths(current)
        // A change to `required` alone keeps the tick (RD 12): it isn't in the content hash.
        for change in steps where change.kind == .changed && change.fields.contains(where: { $0.name != "required" }) {
            guard let path = change.newPath else { continue }
            lines.append("Step \(label(path)) loses its tick")
            if change.fields.contains(where: { $0.name.hasPrefix("question.") }) {
                lines.append("Your answer to step \(label(path)) now counts for an earlier version")
            }
        }
        let wasBlocking = blockingIDs(baseline), isBlocking = blockingIDs(current)
        for id in isBlocking where !wasBlocking.contains(id) || steps.contains(where: { $0.stepID == id && $0.kind == .changed }) {
            guard let path = paths[id] else { continue }
            let held = following(path, in: current)
            if !held.isEmpty { lines.append("\(list(held)) wait for step \(label(path)) again") }
        }
        let oldPaths = StepIdentity.paths(baseline)
        for id in wasBlocking where !isBlocking.contains(id) {
            guard let oldPath = oldPaths[id] else { continue }
            let freed = following(paths[id] ?? oldPath, in: paths[id] == nil ? baseline : current)
            if !freed.isEmpty { lines.append("\(list(freed)) no longer wait for step \(label(oldPath))") }
        }
        return lines
    }

    private static func blockingIDs(_ ins: Instructable) -> [String] {
        StepIdentity.entries(ins).filter { $0.step.blocking == true && $0.step.optional != true }.compactMap(\.step.id)
    }

    /// The top-level steps after `path` up to the next blocking one, then Verify when reached.
    private static func following(_ path: String, in ins: Instructable) -> [String] {
        guard let top = Int(path.split(separator: ".").first ?? "") else { return [] }
        var out: [String] = []
        for (index, step) in ins.steps.enumerated() where index + 1 > top {
            out.append("\(index + 1)")
            if step.blocking == true { return out }
        }
        if ins.verify != nil { out.append("Verify") }
        return out
    }

    /// "3", "3b" for sub-step 3.2.
    static func label(_ path: String) -> String {
        let parts = path.split(separator: ".")
        guard parts.count == 2, let sub = Int(parts[1]), StepLevel.letters.indices.contains(sub - 1) else { return path }
        return String(parts[0]) + StepLevel.letters[sub - 1]
    }

    /// "Step 3", "Steps 3 and 4", "Steps 3, 4 and Verify".
    private static func list(_ labels: [String]) -> String {
        switch labels.count {
        case 1: return labels[0] == "Verify" ? "Verify" : "Step " + labels[0]
        default: return "Steps " + labels.dropLast().joined(separator: ", ") + " and " + labels[labels.count - 1]
        }
    }
}
