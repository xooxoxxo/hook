import Foundation

public struct ValidationFailure: Error, Sendable, Equatable {
    /// "<field path>: <problem>". Never a value, so a pasted credential isn't echoed.
    public let errors: [String]

    public init(errors: [String]) {
        self.errors = errors
    }
}

/// The instructable validator, matching the mailbox service's. Within a step it
/// reports errors in the reference's order; object keys (unknown keys, secrets) are
/// visited in sorted order, so those can differ from Python's document order.
public enum Validator {
    public static let maxBytes = 32768
    static let maxSteps = 20
    static let maxChoices = 6
    static let maxLinks = 10
    static let maxProject = 60
    static let urgencies: Set<String> = ["now", "today", "whenever"]

    static let topKeys: Set<String> = ["v", "title", "why", "urgency", "steps", "verify", "reply", "links", "from"]
    /// Verify: a leaf that asks, blocks and opts out of nothing.
    static let verifyKeys: Set<String> = ["do", "where", "code", "lang", "expect", "detail", "url"]
    /// A sub-step.
    static let leafKeys: Set<String> = verifyKeys.union(["question", "blocking", "warning", "optional", "file"])
    /// `warning`: multi-line, like `detail`.
    static let warningLimit = 300
    /// An entry of `steps`.
    static let stepKeys: Set<String> = leafKeys.union(["substeps"])
    static let maxSubsteps = 10
    /// Steps plus sub-steps per instructable; verify isn't counted.
    static let maxStepTotal = 60
    /// Questions on steps and sub-steps per instructable.
    static let maxQuestions = 20
    static let questionKeys: Set<String> = ["prompt", "choices", "multi"]
    static let replyKeys: Set<String> = ["prompt", "choices"]
    static let linkKeys: Set<String> = ["label", "url", "path"]
    /// `file` and a link's `path`: an absolute local path of at most this many characters.
    static let maxPath = 500
    static let fromKeys = ["session", "host", "cwd"]
    /// Step fields in the reference's order: name, limit, text class.
    static let stepFields: [(name: String, limit: Int, kind: TextKind)] = [
        ("do", 300, .single), ("where", 60, .single), ("code", 4000, .code),
        ("lang", 20, .single), ("expect", 300, .multi), ("detail", 1500, .multi),
    ]

    /// `.path`: a single line where even the emoji joiners (U+200D, U+FE0E, U+FE0F)
    /// count as hidden, as in code, so a file name reads as what it is.
    enum TextKind: Sendable {
        case code, multi, single, path
    }

    /// `.success` holds the cleaned instructable: the input with `urgency`
    /// set to "today" when it is absent or null.
    public static func validate(_ value: JSONValue) -> Result<JSONValue, ValidationFailure> {
        guard case .object(let object) = value else {
            return .failure(ValidationFailure(errors: ["instructable: must be an object"]))
        }
        guard PySize.bytes(value) <= maxBytes else {
            return .failure(ValidationFailure(errors: ["instructable: larger than \(maxBytes) bytes"]))
        }

        var errors: [String] = []
        keys(&errors, "", value, allowed: topKeys)

        if object["v"] != .int(1) {
            errors.append("v: must be 1")
        }
        text(&errors, "title", object["title"], limit: 120, required: true)
        text(&errors, "why", object["why"], limit: 300, kind: .multi)
        if let urgency = present(object["urgency"]),
           urgency.stringValue.map({ urgencies.contains($0) }) != true {
            errors.append("urgency: must be one of now, today, whenever")
        }

        if case .array(let steps)? = present(object["steps"]), (1...maxSteps).contains(steps.count) {
            for (index, item) in steps.enumerated() {
                step(&errors, "steps[\(index)]", item, allowed: stepKeys)
            }
            let total = steps.count + steps.reduce(0) { sum, item in
                if case .object(let members) = item, case .array(let subs)? = members["substeps"] { return sum + subs.count }
                return sum
            }
            if total > maxStepTotal {
                errors.append("steps: more than \(maxStepTotal) steps and sub-steps in total")
            }
            if questionCount(steps) > maxQuestions {
                errors.append("steps: more than \(maxQuestions) questions in total")
            }
        } else {
            errors.append("steps: must be a list of 1 to \(maxSteps) steps")
        }
        if let verify = present(object["verify"]) {
            step(&errors, "verify", verify, allowed: verifyKeys)
        }

        if let replyValue = present(object["reply"]),
           let reply = keys(&errors, "reply", replyValue, allowed: replyKeys) {
            text(&errors, "reply.prompt", reply["prompt"], limit: 300, required: true, kind: .multi)
            if case .array(let choices)? = present(reply["choices"]), choices.count <= maxChoices {
                for (index, choice) in choices.enumerated() {
                    text(&errors, "reply.choices[\(index)]", choice, limit: 60, required: true)
                }
            } else {
                errors.append("reply.choices: must be a list of at most \(maxChoices) choices")
            }
        }

        if let linksValue = present(object["links"]) {
            if case .array(let links) = linksValue, links.count <= maxLinks {
                for (index, linkValue) in links.enumerated() {
                    let path = "links[\(index)]"
                    if let link = keys(&errors, path, linkValue, allowed: linkKeys) {
                        text(&errors, "\(path).label", link["label"], limit: 60, required: true)
                        let hasURL = present(link["url"]) != nil, hasPath = present(link["path"]) != nil
                        if hasURL == hasPath {
                            errors.append("\(path): needs url or path, not both")
                        } else if hasURL {
                            url(&errors, "\(path).url", link["url"], required: true)
                        } else {
                            Self.path(&errors, "\(path).path", link["path"])
                        }
                    }
                }
            } else {
                errors.append("links: must be a list of at most \(maxLinks) links")
            }
        }

        if let originValue = present(object["from"]),
           let origin = keys(&errors, "from", originValue, allowed: Set(fromKeys)) {
            for key in fromKeys {
                text(&errors, "from.\(key)", origin[key])
            }
        }

        secrets(&errors, "", value)
        guard errors.isEmpty else { return .failure(ValidationFailure(errors: errors)) }
        var clean = object
        if present(object["urgency"]) == nil {
            clean["urgency"] = .string("today")
        }
        return .success(.object(clean))
    }

    /// The `project` sent beside an instructable: required, one line, at most
    /// 60 characters, no hidden characters, nothing credential-like.
    public static func validateProject(_ value: JSONValue?) -> [String] {
        var errors: [String] = []
        text(&errors, "project", value, limit: maxProject, required: true)
        if errors.isEmpty, case .string(let name)? = value, looksSecret(name) {
            errors.append("project: secret-like value")
        }
        return errors
    }

    /// The optional note on a resolve, checked like `why`.
    public static func validateNote(_ value: JSONValue?) -> [String] {
        var errors: [String] = []
        text(&errors, "note", value, limit: 300, kind: .multi)
        if errors.isEmpty, case .string(let note)? = value, looksSecret(note) {
            errors.append("note: secret-like value")
        }
        return errors
    }

    /// True when the text, or its skeleton (NFKC with every hidden scalar,
    /// U+200D, U+FE0E and U+FE0F removed), holds one of the 7 reference patterns.
    public static func looksSecret(_ text: String) -> Bool {
        if matchesSecretPattern(Array(text.unicodeScalars)) { return true }
        let skeleton: [Unicode.Scalar] = text.precomposedStringWithCompatibilityMapping.unicodeScalars
            .filter { !Sanitize.isHidden($0, as: .code) }
        return matchesSecretPattern(skeleton)
    }

    // MARK: - Rules

    /// JSON null counts as absent, as Python's `obj.get(key)` sees it.
    static func present(_ value: JSONValue?) -> JSONValue? {
        guard let value, value != .null else { return nil }
        return value
    }

    /// `_text`: at most one error per string, the first that applies.
    static func text(
        _ errors: inout [String], _ path: String, _ value: JSONValue?,
        limit: Int? = nil, required: Bool = false, kind: TextKind = .single
    ) {
        guard let value = present(value) else {
            if required { errors.append("\(path): required") }
            return
        }
        guard case .string(let string) = value else {
            errors.append("\(path): must be a string")
            return
        }
        let scalars = string.unicodeScalars
        if required && scalars.allSatisfy(isPythonSpace) {
            errors.append("\(path): must not be empty")
        } else if let limit, scalars.count > limit {
            errors.append("\(path): longer than \(limit) characters")
        } else if let problem = shape(path, string, kind) {
            errors.append(problem)
        }
    }

    static func shape(_ path: String, _ string: String, _ kind: TextKind) -> String? {
        let cls: FieldClass = kind == .code || kind == .path ? .code : .prose
        if let hidden = string.unicodeScalars.first(where: { Sanitize.isHidden($0, as: cls) }) {
            return "\(path): contains hidden or control characters (U+\(String(format: "%04X", hidden.value)))"
        }
        if (kind == .single || kind == .path) && string.unicodeScalars.contains(where: { $0 == "\n" || $0 == "\t" }) {
            return "\(path): must be a single line"
        }
        return nil
    }

    /// Python's `str.isspace`, which `str.strip()` uses.
    static func isPythonSpace(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x09...0x0D, 0x1C...0x20, 0x85, 0xA0, 0x1680, 0x2000...0x200A,
             0x2028, 0x2029, 0x202F, 0x205F, 0x3000:
            return true
        default:
            return false
        }
    }

    static func url(_ errors: inout [String], _ path: String, _ value: JSONValue?, required: Bool = false) {
        let before = errors.count
        text(&errors, path, value, required: required)
        guard errors.count == before, case .string(let string)? = present(value) else { return }
        if !isHTTPURL(string) {
            errors.append("\(path): must be an http(s) URL")
        }
    }

    /// `_path`: an absolute local path ("/…" or "~/…"), one line of 1 to `maxPath`
    /// characters with no hidden characters, no "." or ".." segment (P1), no first
    /// segment starting with "." such as /.vol or /.nofollow (N2), a first segment that
    /// is plain ASCII (N3: case folding turns "ſystem", "Syﬆem" or the Kelvin sign into
    /// ASCII letters), and not /net, /Network or /home or under them after
    /// `networkForm` (N1). N2, N3 and N1 apply only
    /// to paths starting with "/". Null counts as absent.
    static func path(_ errors: inout [String], _ path: String, _ value: JSONValue?) {
        let before = errors.count
        text(&errors, path, value, limit: maxPath, kind: .path)
        guard errors.count == before, case .string(let string)? = present(value) else { return }
        let scalars = string.unicodeScalars
        let rooted = scalars.starts(with: "/".unicodeScalars)
        if !(rooted || scalars.starts(with: "~/".unicodeScalars)) {
            errors.append("\(path): must be an absolute path")
        } else if scalars.split(separator: "/", omittingEmptySubsequences: false)
            .contains(where: { Array($0) == ["."] || Array($0) == [".", "."] }) {
            errors.append("\(path): must not contain . or .. segments")
        } else if rooted, let first = scalars.split(separator: "/").first, first.first == "." {
            errors.append("\(path): can't start with a hidden folder")
        } else if rooted, let first = scalars.split(separator: "/").first, !first.allSatisfy(\.isASCII) {
            errors.append("\(path): the first folder name must be plain ASCII")
        } else if rooted && isNetworkPath(string) {
            errors.append("\(path): can't be a network path")
        }
    }

    /// Autofs and Finder network roots, in `networkForm`: opening a path under one
    /// reaches a server.
    public static let networkRoots = ["/net", "/network", "/home"]
    /// Prefixes that lead back to the same roots, tried in this order (only at a path
    /// boundary), stripped in a loop until none matches, however they are stacked.
    public static let firmlinkPrefixes = ["/private/var/automount", "/var/automount", "/private", "/system/volumes/data"]

    /// `_network_form`: runs of "/" collapsed into one, lowercased (the disk ignores
    /// case), then `firmlinkPrefixes` entries stripped in a loop until nothing changes.
    public static func networkForm(_ string: String) -> String {
        var collapsed = String.UnicodeScalarView()
        var lastSlash = false
        for scalar in string.unicodeScalars {
            if scalar == "/" && lastSlash { continue }
            lastSlash = scalar == "/"
            collapsed.append(scalar)
        }
        var form = Array(String(collapsed).lowercased().unicodeScalars)
        var changed = true
        while changed {
            changed = false
            for prefix in firmlinkPrefixes {
                let prefixScalars = Array(prefix.unicodeScalars)
                if form == prefixScalars || form.starts(with: prefixScalars + ["/"]) {
                    form = Array(form.dropFirst(prefixScalars.count))
                    if form.isEmpty { form = ["/"] }
                    changed = true
                    break
                }
            }
        }
        return String(String.UnicodeScalarView(form))
    }

    /// `form in NETWORK_ROOTS or form.startswith(root + "/")` on `networkForm(string)`,
    /// compared by scalars as Python compares code points.
    public static func isNetworkPath(_ string: String) -> Bool {
        let scalars = Array(networkForm(string).unicodeScalars)
        return networkRoots.contains { root in
            let rootScalars = Array(root.unicodeScalars)
            return scalars == rootScalars || scalars.starts(with: rootScalars + ["/"])
        }
    }

    /// What `urlparse` accepts as http(s) with a host: scheme (any case) before
    /// the first ":", then "//", then a non-empty authority up to the first
    /// "/", "?" or "#", with balanced brackets and no character that NFKC turns
    /// into "/", "?", "#", "@" or ":". Deliberately not `URL(string:)`.
    static func isHTTPURL(_ text: String) -> Bool {
        let scalars = Array(text.unicodeScalars)
        let colon: Unicode.Scalar = ":", slash: Unicode.Scalar = "/"
        guard let end = scalars.firstIndex(of: colon), end > 0,
              isASCIILetter(scalars[0]),
              scalars[..<end].allSatisfy(isSchemeScalar) else { return false }
        let scheme = String(String.UnicodeScalarView(scalars[..<end])).lowercased()
        guard scheme == "http" || scheme == "https" else { return false }
        let rest = scalars[(end + 1)...]
        guard rest.count >= 2, rest[rest.startIndex] == slash, rest[rest.startIndex + 1] == slash else {
            return false
        }
        let netloc = rest.dropFirst(2).prefix { $0 != "/" && $0 != "?" && $0 != "#" }
        guard !netloc.isEmpty else { return false }
        let opens = netloc.contains("["), closes = netloc.contains("]")
        guard opens == closes else { return false }
        return netlocSurvivesNFKC(netloc)
    }

    static func isASCIILetter(_ scalar: Unicode.Scalar) -> Bool {
        ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar)
    }

    static func isSchemeScalar(_ scalar: Unicode.Scalar) -> Bool {
        isASCIILetter(scalar) || ("0"..."9").contains(scalar) || scalar == "+" || scalar == "-" || scalar == "."
    }

    /// urllib's `_checknetloc`.
    static func netlocSurvivesNFKC(_ netloc: ArraySlice<Unicode.Scalar>) -> Bool {
        guard !netloc.allSatisfy(\.isASCII) else { return true }
        let ignored: Set<Unicode.Scalar> = ["@", ":", "#", "?"]
        let kept = String(String.UnicodeScalarView(netloc.filter { !ignored.contains($0) }))
        let forbidden: Set<Unicode.Scalar> = ["/", "?", "#", "@", ":"]
        return !kept.precomposedStringWithCompatibilityMapping.unicodeScalars.contains { forbidden.contains($0) }
    }

    /// `_step`: `do` required, the rest optional; a `steps` entry may hold 1 to 10
    /// sub-steps, each checked as a leaf (so nesting is an unknown key). A step or
    /// sub-step may ask a `question` and carry `blocking` (a bool), `optional` (a
    /// bool, never together with `blocking`), a multi-line `warning` and `file` (an
    /// absolute local path); verify (`verifyKeys`) can't. An optional parent makes its
    /// sub-steps optional (`inOptional`), so none of them may be blocking. Errors come
    /// in the reference's order: the `stepFields`, url, file, blocking, optional,
    /// warning, question, substeps.
    static func step(
        _ errors: inout [String], _ path: String, _ value: JSONValue, allowed: Set<String>,
        inOptional: Bool = false
    ) {
        guard let step = keys(&errors, path, value, allowed: allowed) else { return }
        for field in stepFields {
            text(&errors, "\(path).\(field.name)", step[field.name], limit: field.limit,
                 required: field.name == "do", kind: field.kind)
        }
        url(&errors, "\(path).url", step["url"])
        if allowed.contains("file") {
            Self.path(&errors, "\(path).file", step["file"])
        }
        if allowed.contains("blocking") {
            let blocking = present(step["blocking"])
            switch blocking {
            case nil, .bool(false)?: break
            case .bool(true)?:
                if inOptional { errors.append("\(path).blocking: can't be blocking inside an optional step") }
            default: errors.append("\(path).blocking: must be true or false")
            }
            switch present(step["optional"]) {
            case nil: break
            case .bool(true)?:
                if blocking == .bool(true) {
                    errors.append("\(path).optional: can't be optional and blocking")
                }
            case .bool?: break
            default: errors.append("\(path).optional: must be true or false")
            }
            text(&errors, "\(path).warning", step["warning"], limit: warningLimit, kind: .multi)
        }
        if allowed.contains("question"), let question = present(step["question"]) {
            Self.question(&errors, "\(path).question", question)
        }
        guard allowed.contains("substeps"), let subsValue = present(step["substeps"]) else { return }
        guard case .array(let subs) = subsValue, (1...maxSubsteps).contains(subs.count) else {
            errors.append("\(path).substeps: must be a list of 1 to \(maxSubsteps) steps")
            return
        }
        for (index, sub) in subs.enumerated() {
            Self.step(&errors, "\(path).substeps[\(index)]", sub, allowed: leafKeys,
                      inOptional: present(step["optional"]) == .bool(true))
        }
    }

    /// `_question`: a prompt, then 0 to 6 distinct choices (none asks for free text)
    /// and `multi`, which allows several picks and needs at least 2 choices.
    static func question(_ errors: inout [String], _ path: String, _ value: JSONValue) {
        guard let question = keys(&errors, path, value, allowed: questionKeys) else { return }
        text(&errors, "\(path).prompt", question["prompt"], limit: 300, required: true, kind: .multi)
        var count: Int? = 0   // nil: the choices are malformed
        if let choicesValue = present(question["choices"]) {
            if case .array(let choices) = choicesValue, choices.count <= maxChoices {
                var seen = Set<[UInt32]>()   // by code point, as Python compares strings
                for (index, choice) in choices.enumerated() {
                    let before = errors.count
                    text(&errors, "\(path).choices[\(index)]", choice, limit: 60, required: true)
                    guard errors.count == before, case .string(let string) = choice else { continue }
                    if !seen.insert(string.unicodeScalars.map(\.value)).inserted {
                        errors.append("\(path).choices[\(index)]: duplicate choice")
                    }
                }
                count = choices.count
            } else {
                errors.append("\(path).choices: must be a list of at most \(maxChoices) choices")
                count = nil
            }
        }
        switch present(question["multi"]) {
        case nil, .bool(false)?:
            break
        case .bool(true)?:
            if let count, count < 2 { errors.append("\(path).multi: needs at least 2 choices") }
        default:
            errors.append("\(path).multi: must be true or false")
        }
    }

    /// `_every_step` counted: each step object, then each object in its `substeps`
    /// list (any length), that holds a non-null `question`.
    static func questionCount(_ steps: [JSONValue]) -> Int {
        var count = 0
        for case .object(let step) in steps {
            if present(step["question"]) != nil { count += 1 }
            if case .array(let subs)? = step["substeps"] {
                for case .object(let sub) in subs where present(sub["question"]) != nil { count += 1 }
            }
        }
        return count
    }

    /// `_keys`: the members of an object, after reporting each unknown key;
    /// nil (and "must be an object") when the value isn't an object.
    @discardableResult
    static func keys(
        _ errors: inout [String], _ path: String, _ value: JSONValue, allowed: Set<String>
    ) -> [String: JSONValue]? {
        guard case .object(let members) = value else {
            errors.append("\(path): must be an object")
            return nil
        }
        for key in members.keys.sorted() where !allowed.contains(key) {
            errors.append("\(join(path, key)): unknown key")
        }
        return members
    }

    /// `_secrets`: every string value anywhere, by path.
    static func secrets(_ errors: inout [String], _ path: String, _ value: JSONValue) {
        switch value {
        case .string(let string):
            if looksSecret(string) { errors.append("\(path): secret-like value") }
        case .object(let members):
            for key in members.keys.sorted() {
                if let inner = members[key] { secrets(&errors, join(path, key), inner) }
            }
        case .array(let items):
            for (index, inner) in items.enumerated() {
                secrets(&errors, "\(path)[\(index)]", inner)
            }
        default:
            break
        }
    }

    static func join(_ path: String, _ key: String) -> String {
        path.isEmpty ? name(key) : "\(path).\(name(key))"
    }

    /// A key as it may appear in an error: redacted when it looks like a
    /// credential or holds a hidden scalar (code class), else its first 60 scalars.
    static func name(_ key: String) -> String {
        if looksSecret(key) || key.unicodeScalars.contains(where: { Sanitize.isHidden($0, as: .code) }) {
            return "<redacted>"
        }
        return String(String.UnicodeScalarView(key.unicodeScalars.prefix(60)))
    }

    // MARK: - The 7 patterns, matched by hand (no Regex, which isn't Sendable)

    static func matchesSecretPattern(_ s: [Unicode.Scalar]) -> Bool {
        for i in s.indices {
            if has(s, i, "sk-ant-") || has(s, i, "xoxa-") || has(s, i, "xoxb-") || has(s, i, "xoxp-")
                || has(s, i, "ghp_") || has(s, i, "github_pat_") {
                return true
            }
            // \bsk-[A-Za-z0-9]{20,}
            if has(s, i, "sk-"), i == 0 || !isWordScalar(s[i - 1]),
               s[(i + 3)...].prefix(while: isASCIIAlphanumeric).count >= 20 {
                return true
            }
            // AKIA[0-9A-Z]{16}
            if has(s, i, "AKIA"),
               s[(i + 4)...].prefix(while: { ("0"..."9").contains($0) || ("A"..."Z").contains($0) }).count >= 16 {
                return true
            }
            // -----BEGIN [A-Z ]*PRIVATE KEY-----
            if has(s, i, "-----BEGIN ") {
                let start = i + 11
                let run = s[start...].prefix { ("A"..."Z").contains($0) || $0 == " " }
                if run.reversed().starts(with: "PRIVATE KEY".unicodeScalars.reversed()),
                   has(s, start + run.count, "-----") {
                    return true
                }
            }
        }
        return false
    }

    static func has(_ s: [Unicode.Scalar], _ at: Int, _ literal: String) -> Bool {
        let pattern = literal.unicodeScalars
        guard at + pattern.count <= s.count else { return false }
        return zip(s[at...], pattern).allSatisfy { $0 == $1 }
    }

    static func isASCIIAlphanumeric(_ scalar: Unicode.Scalar) -> Bool {
        isASCIILetter(scalar) || ("0"..."9").contains(scalar)
    }

    /// Python's `\w` for str patterns: letters, numbers and "_".
    static func isWordScalar(_ scalar: Unicode.Scalar) -> Bool {
        if scalar == "_" { return true }
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
             .decimalNumber, .letterNumber, .otherNumber:
            return true
        default:
            return scalar.properties.numericType != nil
        }
    }
}
