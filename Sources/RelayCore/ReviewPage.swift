import Foundation

/// The inline review of a corrected ask, as the detail draws it: every step of the version
/// under review in order, a unified diff under each one that changed with its Look-closer flags
/// right below, then what else changed, what resets, and the bar's count and buttons. Built
/// from `RevisionDiff` and `LookCloser` alone; ask text in it is revealed (`Sanitize`).
public struct ReviewPage: Equatable, Sendable {
    /// A reason the session gave, with its version and time.
    public struct Reason: Equatable, Sendable {
        public var rev: Int
        public var time: String
        /// "The session says: …" (`ReviewText.reason`).
        public var text: String

        /// "Version 3 · 10:42".
        public var heading: String { time.isEmpty ? "Version \(rev)" : "Version \(rev) · \(time)" }
    }

    /// A Look-closer flag as one line and where it was found.
    public struct Flag: Equatable, Sendable {
        public var kind: LookCloserFlag.Kind
        /// "New host deploy.example.net · not in version 1", "Runs as root: sudo".
        public var title: String
        /// "Step 3", "Verify", "Link 2", "Why".
        public var place: String
    }

    /// One field's unified diff: a "−" line (absent for an added field) over a "+" line
    /// (absent for a removed one).
    public struct Field: Equatable, Sendable {
        /// "Detail", "Expect", "Link"; nil for the command itself.
        public var label: String?
        public var tokens: [DiffToken]
        public var hasOld: Bool
        public var hasNew: Bool
        /// Drawn monospaced (a command, a URL, a path).
        public var monospaced: Bool
    }

    public enum Change: Equatable, Sendable {
        case same, changed, added, moved, removed
    }

    /// One step, sub-step, or other part of the ask (Why, Verify, Reply, a link).
    public struct Row: Equatable, Sendable, Identifiable {
        /// Stable within the page: the step id, else the part's name.
        public var id: String
        /// "3", "3b", "Verify", "Link 2".
        public var label: String
        public var action: String
        /// The step's text before, when it changed.
        public var was: String?
        public var change: Change
        public var isSub: Bool
        /// "Moved from step 2".
        public var note: String?
        public var fields: [Field]
        public var flags: [Flag]
        /// Drawn dimmed: an unchanged step with nothing under it. Never on a first view, where
        /// every row is untagged and all of it is to be read, and never with fields or flags.
        public var dimmed: Bool

        /// "Changed", "New", "Removed", "Moved"; nil for an unchanged row and on a first view.
        public var tag: String? {
            switch change {
            case .same: return nil
            case .changed: return "Changed"
            case .added: return "New"
            case .removed: return "Removed"
            case .moved: return "Moved"
            }
        }
    }

    /// The version under review; Use Version N accepts exactly this.
    public var target: RevisionStamp
    /// The newest verified version; above `target` when one arrived during the review.
    public var latest: RevisionStamp
    public var isFirstView: Bool
    /// "Reviewing version 3 of 3 · 10:42".
    public var heading: String
    /// "Changes since version 1" or, on a first view, what it shows instead.
    public var since: String
    /// Who changed it: the holder of the edit key (`ReviewText.attribution`).
    public var attribution: String
    public var reasons: [Reason]
    /// The steps of `target` in order, then the removed ones.
    public var steps: [Row]
    /// Why, Verify, Reply and links that changed.
    public var others: [Row]
    public var resets: [String]
    /// A command, link or file changed: Use Version N asks for Touch ID.
    public var needsPresence: Bool

    public var isStale: Bool { latest.rev > target.rev }
    public var flagCount: Int { (steps + others).reduce(0) { $0 + $1.flags.count } }

    /// "2 changed · 1 added"; "4 steps" on a first view.
    public var stepsSummary: String {
        if isFirstView { return steps.count == 1 ? "1 step" : "\(steps.count) steps" }
        let counts: [(Change, String)] = [(.changed, "changed"), (.added, "added"), (.removed, "removed"), (.moved, "moved")]
        let parts = counts.compactMap { change, word -> String? in
            let n = steps.filter { $0.change == change }.count
            return n == 0 ? nil : "\(n) \(word)"
        }
        return parts.isEmpty ? "No step changed" : parts.joined(separator: " · ")
    }

    // MARK: The bar

    /// "2 flags to look closer at", "No pattern matched", or the newer version's line.
    public var barTitle: String {
        if isStale { return "Version \(latest.rev) arrived during your review" }
        switch flagCount {
        case 0: return "No flags"
        case 1: return "1 flag to look closer at"
        default: return "\(flagCount) flags to look closer at"
        }
    }

    public var barDetail: String {
        if isStale { return "Show it before you use it. Version \(target.rev) can no longer be used." }
        return flagCount == 0 ? LookCloser.incomplete : "Hook checks a few patterns only. These checks are incomplete."
    }

    /// "Use Version 3", or "Show Version 4" once a newer one arrived (it never accepts 3).
    public var primaryTitle: String {
        isStale ? ReviewText.showNewerButton(rev: latest.rev - 1) : ReviewText.useButton(rev: target.rev)
    }

    public static let notNow = "Not Now"
    public static let presenceNote = "Changes a command, link or file: Touch ID or your password."
    public static let editKeyHelp = "Only the session that posted an ask holds its edit key, so only it can correct the ask. "
        + "The key sits in a file on that Mac, so any process there could use it. That is why Hook shows you every "
        + "change before you can copy anything."
    public static let lookCloserHelp = "Hook looks for new hosts, sudo, rm -rf, a download piped into a shell, "
        + "base64 -d, eval, paths outside the session's folder and characters that aren't plain ASCII. "
        + "These checks are incomplete: no flag never means safe."

    // MARK: Building

    /// - `target`: the version under review, `latest` the newest one verified;
    /// - `body`: target's body; `baselineRev`: the revision diffed from (nil on a first view);
    /// - `time`: a revision's time as the page shows it ("10:42"), "" when unknown.
    public static func make(diff: RevisionDiff, flags: [LookCloserFlag], body: Instructable, target: RevisionStamp,
                            latest: RevisionStamp, baselineRev: Int?, time: (Int) -> String) -> ReviewPage {
        let first = diff.isFirstView || baselineRev == nil
        let paths = StepIdentity.paths(body)
        let flagRows = place(flags, paths: paths, baselineRev: first ? nil : baselineRev)
        let changes = Dictionary(diff.steps.map { ($0.stepID, $0) }) { a, _ in a }

        var steps: [Row] = []
        for entry in StepIdentity.entries(body) {
            let id = entry.step.id ?? entry.path
            let change = changes[id]
            let fields = change.map { stepFields($0.fields) } ?? []
            let wasAction = change?.fields.first { $0.name == "do" }?.old
            var kind: Change = .same
            if let change, !first {
                switch change.kind {
                case .changed: kind = .changed
                case .added: kind = .added
                case .moved: kind = .moved
                case .removed: kind = .removed
                }
            }
            let shownFields = first || (kind != .same && kind != .moved) ? fields : []
            let stepFlags = flagRows["step " + id] ?? []
            steps.append(Row(
                id: id, label: RevisionDiff.label(entry.path), action: Sanitize.revealLine(entry.step.action),
                was: kind == .changed ? wasAction.map(Sanitize.revealLine) : nil, change: kind,
                isSub: entry.path.contains("."),
                note: kind == .moved ? change?.oldPath.map { "Moved from step " + RevisionDiff.label($0) } : nil,
                fields: shownFields, flags: stepFlags,
                dimmed: dims(kind, fields: shownFields, flags: stepFlags, first: first)))
        }
        if !first {
            for change in diff.steps where change.kind == .removed {
                let action = change.fields.first { $0.name == "do" }?.old ?? ""
                steps.append(Row(
                    id: "removed:" + change.stepID, label: change.oldPath.map(RevisionDiff.label) ?? "",
                    action: Sanitize.revealLine(action), was: nil, change: .removed,
                    isSub: change.oldPath?.contains(".") ?? false, note: nil,
                    fields: stepFields(change.fields), flags: [], dimmed: false))
            }
        }

        return ReviewPage(
            target: target, latest: latest, isFirstView: first,
            heading: "Reviewing version \(target.rev) of \(latest.rev)" + (time(target.rev).isEmpty ? "" : " · " + time(target.rev)),
            since: first ? ReviewText.firstViewHeading + ": every step is shown, as posted and corrected."
                : ReviewText.sinceHeading(rev: baselineRev ?? 1) + ", the version this Mac last showed you.",
            attribution: ReviewText.attribution(session: body.from?.session, host: body.from?.host),
            reasons: diff.reasons.map { Reason(rev: $0.rev, time: time($0.rev), text: ReviewText.reason($0.reason)) },
            steps: steps, others: others(diff.top, body: body, flags: flagRows, first: first),
            resets: diff.resets, needsPresence: diff.touchesCommandsLinksOrFiles)
    }

    /// Only an unchanged row with no diff and no flag under it is dimmed, and none on a first
    /// view: there `.same` means untagged, and every command and flag is still to be read.
    public static func dims(_ change: Change, fields: [Field], flags: [Flag], first: Bool) -> Bool {
        !first && change == .same && fields.isEmpty && flags.isEmpty
    }

    // MARK: Fields

    /// Every field but the step's text (shown as the row's title, with "Was:").
    static func stepFields(_ diffs: [FieldDiff]) -> [Field] {
        diffs.filter { $0.name != "do" }.map { field($0, name: $0.name) }
    }

    static func field(_ diff: FieldDiff, name: String) -> Field {
        let leaf = name.split(separator: ".").last.map(String.init) ?? name
        let monospaced = ["code", "url", "file", "path"].contains(leaf)
        let cls: FieldClass = leaf == "code" ? .code : .prose
        let tokens = diff.tokens.map { token -> DiffToken in
            let shown = Sanitize.reveal(token.text, as: cls).text
            switch token {
            case .same: return .same(shown)
            case .removed: return .removed(shown)
            case .added: return .added(shown)
            }
        }
        return Field(label: label(name), tokens: tokens, hasOld: diff.old != nil, hasNew: diff.new != nil,
                     monospaced: monospaced)
    }

    /// The field's name as the review shows it; nil for a command (the diff speaks for itself).
    static func label(_ name: String) -> String? {
        let parts = name.split(separator: ".").map(String.init)
        let leaf = parts.last ?? name
        if parts.first == "links", parts.count == 3 {
            return ["label": "Label", "url": "Address", "path": "File"][leaf] ?? leaf
        }
        if leaf == "code" { return nil }
        if parts.first == "reply" { return leaf == "prompt" ? "Prompt" : "Choices" }
        let labels = ["do": "Text", "where": "Where", "detail": "Detail", "lang": "Language", "expect": "Expect",
                      "url": "Link", "file": "File", "warning": "Warning", "blocking": "Blocking", "optional": "Optional",
                      "prompt": "Question", "choices": "Choices", "multi": "More than one answer", "why": "Why"]
        return labels[leaf] ?? leaf
    }

    /// Why, Verify, Reply and each link that changed, one row each.
    static func others(_ top: [FieldDiff], body: Instructable, flags: [String: [Flag]], first: Bool) -> [Row] {
        var order: [String] = []
        var grouped: [String: [FieldDiff]] = [:]
        for diff in top {
            let parts = diff.name.split(separator: ".").map(String.init)
            let key = parts.first == "links" && parts.count == 3 ? "link " + parts[1] : (parts.first ?? diff.name)
            if grouped[key] == nil { order.append(key) }
            grouped[key, default: []].append(diff)
        }
        return order.map { key in
            let diffs = grouped[key] ?? []
            let label: String
            let action: String
            var fields = diffs
            switch key {
            case "why":
                label = "Why"
                action = "The reason for the ask"
            case "verify":
                label = "Verify"
                action = Sanitize.revealLine(body.verify?.action ?? diffs.first { $0.name == "verify.do" }?.old ?? "")
                fields = diffs.filter { $0.name != "verify.do" }
            case "reply":
                label = "Reply"
                action = "What the session asks you to answer"
            default:
                let n = key.dropFirst("link ".count)
                label = "Link \(n)"
                let index = (Int(n) ?? 0) - 1
                let link = (body.links ?? []).indices.contains(index) ? body.links?[index] : nil
                action = Sanitize.revealLine(link?.label ?? link?.url ?? link?.path ?? "Removed")
            }
            let removed = diffs.allSatisfy { $0.new == nil }
            let added = diffs.allSatisfy { $0.old == nil }
            let was = key == "verify" ? diffs.first { $0.name == "verify.do" && $0.old != nil && $0.new != nil }?.old : nil
            let change: Change = first ? .same : (removed ? .removed : (added ? .added : .changed))
            let shown = fields.map { field($0, name: $0.name) }
            let rowFlags = flags[key] ?? []
            return Row(id: key, label: label, action: action, was: first ? nil : was.map(Sanitize.revealLine),
                       change: change, isSub: false, note: nil, fields: shown, flags: rowFlags,
                       dimmed: dims(change, fields: shown, flags: rowFlags, first: first))
        }
    }

    // MARK: Flags

    /// Flags by where they belong: "step <id>", "verify", "link <n>", "why".
    static func place(_ flags: [LookCloserFlag], paths: [String: String], baselineRev: Int?) -> [String: [Flag]] {
        var out: [String: [Flag]] = [:]
        for flag in flags {
            let parts = flag.location.split(separator: " ").map(String.init)
            let key: String
            let place: String
            switch parts.first {
            case "step"? where parts.count >= 2:
                key = "step " + parts[1]
                place = "Step " + (paths[parts[1]].map(RevisionDiff.label) ?? parts[1])
            case "link"? where parts.count >= 2:
                key = "link " + parts[1]
                place = "Link " + parts[1]
            case "verify"?:
                key = "verify"
                place = "Verify"
            default:
                key = parts.first ?? flag.location
                place = key.prefix(1).uppercased() + key.dropFirst()
            }
            out[key, default: []].append(Flag(kind: flag.kind, title: title(flag, baselineRev: baselineRev), place: place))
        }
        return out
    }

    /// The flag as one line, its matched text revealed.
    public static func title(_ flag: LookCloserFlag, baselineRev: Int?) -> String {
        let text = Sanitize.revealLine(flag.text)
        switch flag.kind {
        case .newHost: return "New host " + text + (baselineRev.map { " · not in version \($0)" } ?? "")
        case .pipeToShell: return "A download piped into a shell: " + text
        case .sudo: return "Runs as root: sudo"
        case .rmRf: return "Deletes recursively: " + text
        case .decode: return "Decodes hidden content: " + text
        case .eval: return "Runs generated code: " + text
        case .nonASCII: return "Characters that aren't plain ASCII: " + text
        case .absolutePathOutsideCwd: return "A path outside the session's folder: " + text
        }
    }
}

/// The bar that takes the action bar's place while an ask is locked and not being reviewed.
public struct ReviewLockBar: Equatable, Sendable {
    public enum Tone: Equatable, Sendable { case correction, history }

    public var tone: Tone
    public var title: String
    public var detail: String
    /// "Show Changes" or "Trust the Pond's History Again…".
    public var action: String

    public static let lockHelp = "Until you review the correction, Copy, links, files, answers, ticks and Done are off. "
        + "Skip still works. Using a version that changes a command, link or file asks for Touch ID."
    public static let historyHelp = "The Pond served a history that doesn't match what this Mac saw: a revision is "
        + "missing, changed or older. That happens after a Pond restore, or when someone swapped it. Trust it again "
        + "only after a restore you made."
    public static let showChanges = "Show Changes"
    /// The plan's ActionBar line while locked.
    public static let reviewFirst = "Review the correction first."

    /// nil for a legacy or current ask.
    public static func make(_ state: ReviewState) -> ReviewLockBar? {
        switch state {
        case .legacy, .current:
            return nil
        case .pending(let shown, let current, let baseline):
            let corrections = current.rev - (baseline ?? 1)
            let counted = corrections == 1 ? "1 correction" : "\(corrections) corrections"
            return ReviewLockBar(
                tone: .correction,
                title: shown == nil ? "Corrected before this Mac showed it" : "Corrected after you saw it",
                detail: "Version \(current.rev) of \(current.rev) · \(counted). Copy, links and Done are off until you review.",
                action: showChanges)
        case .historyChanged:
            return ReviewLockBar(
                tone: .history, title: "This ask's history changed on the Pond",
                detail: "Don't act on it: skip it, or trust the Pond's history again after a restore.",
                action: "Trust the Pond's History Again…")
        }
    }
}
