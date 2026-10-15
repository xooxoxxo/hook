import Foundation

/// Where an ask came from, built from an instructable's `from` object. Every value
/// is untrusted: the strings stay raw here, and the view passes each displayed one
/// through `Sanitize`. `resumeCommand` is only built from values that pass its checks.
public struct AskOrigin: Sendable, Equatable {
    /// Trimmed; nil if empty.
    public let host: String?
    /// Trimmed; nil if empty.
    public let cwd: String?
    /// A Claude Code session id: nil unless it matches `^[A-Za-z0-9][A-Za-z0-9-]{7,63}$`.
    public let session: String?

    static let maxCommandPath = 1024

    /// Nil when there is nothing usable.
    public init?(from origin: Origin?) {
        guard let origin else { return nil }
        let host = Self.trimmed(origin.host)
        let cwd = Self.trimmed(origin.cwd)
        let session = origin.session.flatMap { Self.isSessionID($0) ? $0 : nil }
        guard host != nil || cwd != nil || session != nil else { return nil }
        self.host = host
        self.cwd = cwd
        self.session = session
    }

    /// The last path component of `cwd`.
    public var folder: String? {
        guard let cwd else { return nil }
        let parts = cwd.split(separator: "/", omittingEmptySubsequences: true)
        guard let last = parts.last else { return cwd }   // "/" or "///"
        return String(last)
    }

    /// The first 8 characters of `session`.
    public var shortSession: String? {
        session.map { String($0.prefix(8)) }
    }

    /// "folder · host · shortSession", without the missing parts.
    public var summary: String {
        [folder, host, shortSession].compactMap { $0 }.joined(separator: " · ")
    }

    /// The From row's tooltip: "Folder: …", "Host: …", "Session: …", one per line,
    /// in full and without the missing parts. Raw: the view reveals each line.
    public var helpLines: [String] {
        var lines: [String] = []
        if let cwd { lines.append("Folder: " + cwd) }
        if let host { lines.append("Host: " + host) }
        if let session { lines.append("Session: " + session) }
        return lines
    }

    /// `cd '<cwd>' && claude --resume <session>`, with each `'` in the path written
    /// as `'\''`. Only when the session is valid and the path is absolute, at most
    /// 1024 characters, and free of control and hidden characters.
    public var resumeCommand: String? {
        guard let session, let cwd, Self.isSafePath(cwd) else { return nil }
        let quoted = cwd.replacingOccurrences(of: "'", with: #"'\''"#)
        return "cd '\(quoted)' && claude --resume \(session)"
    }

    // MARK: - Checks

    static func isSessionID(_ value: String) -> Bool {
        let scalars = Array(value.unicodeScalars)
        guard (8...64).contains(scalars.count) else { return false }
        func alnum(_ s: Unicode.Scalar) -> Bool {
            ("a"..."z").contains(s) || ("A"..."Z").contains(s) || ("0"..."9").contains(s)
        }
        guard alnum(scalars[0]) else { return false }
        return scalars.dropFirst().allSatisfy { alnum($0) || $0 == "-" }
    }

    static func isSafePath(_ path: String) -> Bool {
        guard path.hasPrefix("/"), path.unicodeScalars.count <= maxCommandPath else { return false }
        return path.unicodeScalars.allSatisfy { scalar in
            // TAB and LF are allowed by the display rule but not in a command.
            scalar.value >= 0x20 && scalar.value != 0x7F && !Sanitize.isHidden(scalar, as: .code)
        }
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let value else { return nil }
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}
