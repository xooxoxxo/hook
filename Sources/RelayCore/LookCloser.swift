import Foundation

/// One "Look closer" flag in the review: a pattern worth a second look in added or changed text.
public struct LookCloserFlag: Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable {
        case newHost, pipeToShell, sudo, rmRf, decode, eval, nonASCII, absolutePathOutsideCwd
    }

    public var kind: Kind
    /// Where it was found: "step s3 code", "verify code", "link 2 url". (The plan's `where`,
    /// a Swift keyword.)
    public var location: String
    /// The matched text: the host, the path, or the part of the command.
    public var text: String

    public init(kind: Kind, location: String, text: String) {
        self.kind = kind; self.location = location; self.text = text
    }
}

/// Patterns for the review's "Look closer". They never judge: when nothing matches the
/// review says the checks are incomplete, never "safe".
public enum LookCloser {
    public static let incomplete = "No pattern matched. These checks are incomplete."

    /// Flags in the text `new` added or changed since `old`; every text of `new` when `old`
    /// is nil (a first view). Hosts and paths count as new when `old` doesn't name them anywhere.
    public static func flags(old: Instructable?, new: Instructable, cwd: String?) -> [LookCloserFlag] {
        let before = old.map(texts) ?? []
        let previous = Dictionary(before.map { ($0.location, $0.value) }) { first, _ in first }
        let oldHosts = Set(before.flatMap { hosts(in: $0.value) })
        let oldPaths = Set(before.filter(\.isPath).map(\.value))
        var flags: [LookCloserFlag] = []
        for text in texts(new) where previous[text.location] != text.value {
            if text.isCode {
                for (kind, pattern) in commandPatterns {
                    for match in matches(pattern, in: text.value) {
                        flags.append(LookCloserFlag(kind: kind, location: text.location, text: match))
                    }
                }
                if text.value.unicodeScalars.contains(where: { $0.value > 0x7F }) {
                    flags.append(LookCloserFlag(kind: .nonASCII, location: text.location, text: nonASCII(text.value)))
                }
            }
            for host in hosts(in: text.value) where !oldHosts.contains(host) {
                flags.append(LookCloserFlag(kind: .newHost, location: text.location, text: host))
                if !text.isCode, host.unicodeScalars.contains(where: { $0.value > 0x7F }) {
                    flags.append(LookCloserFlag(kind: .nonASCII, location: text.location, text: nonASCII(host)))
                }
            }
            if text.isPath, !oldPaths.contains(text.value), isAbsolute(text.value), !inside(text.value, cwd: cwd) {
                flags.append(LookCloserFlag(kind: .absolutePathOutsideCwd, location: text.location, text: text.value))
            }
        }
        return flags
    }

    // MARK: Patterns

    static let commandPatterns: [(LookCloserFlag.Kind, String)] = [
        (.pipeToShell, #"\b(?:curl|wget)\b[^|\n]*\|\s*(?:sudo\s+)?(?:sh|bash|zsh|python3?)\b"#),
        (.pipeToShell, #"\b(?:bash|sh|zsh)\s*<\(\s*(?:curl|wget)\b"#),
        (.sudo, #"(?:^|[\s;&|(])sudo\s"#),
        (.rmRf, #"\brm\s+-[A-Za-z]*(?:[rR][A-Za-z]*f|f[A-Za-z]*[rR])"#),
        (.decode, #"\bbase64\s+(?:-d|-D|--decode)\b"#),
        (.decode, #"\bopenssl\s+base64\s+-d\b"#),
        (.decode, #"\bxxd\s+-r\b"#),
        (.eval, #"\beval\s+["']?\$\("#),
    ]

    static func matches(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range, in: text).map { String(text[$0]).trimmingCharacters(in: .whitespaces) }
        }
    }

    /// The host of every http(s) URL in the text, lowercased.
    static func hosts(in text: String) -> [String] {
        matches(#"https?://[^/\s:'"?#<>)]+"#, in: text).map {
            String($0.drop { $0 != "/" }.drop { $0 == "/" }).lowercased()
        }
    }

    /// The text with every non-ASCII scalar shown as ⟨U+…⟩, so the flag says which.
    static func nonASCII(_ text: String) -> String {
        var out = ""
        for scalar in text.unicodeScalars {
            if scalar.value > 0x7F { out += String(format: "⟨U+%04X⟩", scalar.value) } else { out.unicodeScalars.append(scalar) }
        }
        return out
    }

    static func isAbsolute(_ path: String) -> Bool { path.hasPrefix("/") || path.hasPrefix("~") }

    static func inside(_ path: String, cwd: String?) -> Bool {
        guard let cwd, !cwd.isEmpty else { return false }
        let base = cwd.hasSuffix("/") ? cwd : cwd + "/"
        return path == cwd || path.hasPrefix(base)
    }

    // MARK: Texts

    struct Text {
        var location: String
        var value: String
        var isCode = false
        var isPath = false
    }

    /// Every text a pattern can apply to, by a location stable across revisions (step ids).
    static func texts(_ ins: Instructable) -> [Text] {
        var out: [Text] = []
        func add(_ step: Step, _ name: String) {
            if let code = step.code { out.append(Text(location: name + " code", value: code, isCode: true)) }
            if let url = step.url { out.append(Text(location: name + " url", value: url)) }
            if let detail = step.detail { out.append(Text(location: name + " detail", value: detail)) }
            if let file = step.file { out.append(Text(location: name + " file", value: file, isPath: true)) }
        }
        for entry in StepIdentity.entries(ins) { add(entry.step, "step " + (entry.step.id ?? entry.path)) }
        if let verify = ins.verify { add(verify, "verify") }
        for (i, link) in (ins.links ?? []).enumerated() {
            if let url = link.url { out.append(Text(location: "link \(i + 1) url", value: url)) }
            if let path = link.path { out.append(Text(location: "link \(i + 1) path", value: path, isPath: true)) }
        }
        if let why = ins.why { out.append(Text(location: "why", value: why)) }
        return out
    }
}

/// The review's model strings, shared by either design, so they are tested once. Ask text
/// in them is revealed (`Sanitize`), so a hidden character shows as ⟨U+…⟩.
public enum ReviewText {
    /// "Version 3 of 3 · 10:42".
    public static func header(rev: Int, of total: Int, time: String) -> String {
        "Version \(rev) of \(total) · " + Sanitize.revealLine(time)
    }

    /// Who changed it: never "the session", which Hook can't know; the edit key's holder.
    public static func attribution(session: String?, host: String?) -> String {
        let short = session.map { Sanitize.revealLine(String($0.prefix(8))) } ?? "unknown"
        let place = host.map(Sanitize.revealLine) ?? "an unknown Mac"
        return "Posted by session \(short) on \(place). Changed by the holder of this ask's edit key: "
            + "any process on that Mac can read it."
    }

    public static let reasonPrefix = "The session says:"
    public static let firstViewHeading = "First time on this Mac"

    /// "The session says: <reason>", the reason on one line with hidden characters revealed.
    public static func reason(_ text: String) -> String { reasonPrefix + " " + Sanitize.revealLine(text) }

    public static func sinceHeading(rev: Int) -> String { "Changes since version \(rev)" }
    public static func useButton(rev: Int) -> String { "Use Version \(rev)" }
    /// The button that replaces Use Version N when a newer version arrives during the review.
    public static func showNewerButton(rev: Int) -> String { "Show Version \(rev + 1)" }
}
