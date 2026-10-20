import Foundation

public enum ConnectInfoError: Error, Sendable, Equatable, LocalizedError {
    /// Something is already at the skill path; it was left alone.
    case skillPresent(String)
    /// The repo has no skill/instructables folder.
    case skillSourceMissing(String)

    public var errorDescription: String? {
        switch self {
        case .skillPresent(let path):
            return "Something is already at \(path), so it was left alone"
        case .skillSourceMissing(let path):
            return "The repo has no skill folder at \(path)"
        }
    }
}

/// What Settings → Connect shows and copies.
/// Pure apart from reading the repo and the home folder, which the tests point
/// at a temp folder.
public enum ConnectInfo {
    /// A minimal valid instructable, as one line of JSON.
    public static let exampleInstructable =
        #"{"v": 1, "title": "Approve the Acme release", "steps": [{"do": "Open the release page and press Approve"}]}"#

    /// The user-scope MCP registration, as install.sh runs it.
    public static func mcpCommand(repoPath: String) -> String {
        "claude mcp add --scope user relay -- python3 " + doubleQuoted(normalized(repoPath) + "/mcp/relay_mcp.py")
    }

    /// Posting from a shell when MCP servers are blocked.
    public static func cliExample() -> String {
        "relay post Acme --json - <<'EOF'\n" + exampleInstructable + "\nEOF"
    }

    /// The optional replies hook for ~/.claude/settings.json.
    public static func hookSnippet() -> String {
        """
        {
          "hooks": {
            "UserPromptSubmit": [
              {
                "hooks": [
                  {
                    "type": "command",
                    "command": "relay replies --new --hook",
                    "timeout": 5
                  }
                ]
              }
            ]
          }
        }
        """
    }

    /// The text of <repoPath>/docs/claude-md-section.md; nil when missing or blank.
    public static func claudeMdSection(repoPath: String) -> String? {
        let url = URL(fileURLWithPath: normalized(repoPath)).appending(path: "docs/claude-md-section.md")
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }

    public enum SkillState: Sendable, Equatable {
        case installed
        case missing
        /// Where the path points instead (or the path itself, for a real folder).
        case elsewhere(String)
    }

    public static func skillPath(home: URL) -> URL {
        home.appending(path: ".claude/skills/instructables")
    }

    public static func skillSource(repoPath: String) -> URL {
        URL(fileURLWithPath: normalized(repoPath)).appending(path: "skill/instructables")
    }

    public static func skillState(home: URL, repoPath: String) -> SkillState {
        let fm = FileManager.default
        let link = skillPath(home: home).path
        guard (try? fm.attributesOfItem(atPath: link)) != nil else { return .missing }   // lstat: a dangling link counts
        guard let destination = try? fm.destinationOfSymbolicLink(atPath: link) else { return .elsewhere(link) }
        let source = skillSource(repoPath: repoPath)
        var isDirectory: ObjCBool = false
        if fm.fileExists(atPath: source.path, isDirectory: &isDirectory), isDirectory.boolValue,
           URL(fileURLWithPath: link).resolvingSymlinksInPath().path == source.resolvingSymlinksInPath().path {
            return .installed
        }
        if destination.hasPrefix("/") { return .elsewhere(destination) }
        return .elsewhere(URL(fileURLWithPath: link).deletingLastPathComponent()
            .appending(path: destination).standardizedFileURL.path)
    }

    /// Links ~/.claude/skills/instructables to the repo's skill folder. Never
    /// replaces anything already at that path.
    public static func installSkill(home: URL, repoPath: String) throws {
        let fm = FileManager.default
        let source = skillSource(repoPath: repoPath)
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: source.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ConnectInfoError.skillSourceMissing(source.path)
        }
        let link = skillPath(home: home)
        guard (try? fm.attributesOfItem(atPath: link.path)) == nil else {
            throw ConnectInfoError.skillPresent(link.path)
        }
        try fm.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: link.path, withDestinationPath: source.path)
    }

    public static func cliPath(home: URL) -> URL {
        home.appending(path: ".local/bin/relay")
    }

    /// `fileExists` follows links, so a dangling link is "not installed".
    public static func cliInstalled(home: URL) -> Bool {
        FileManager.default.fileExists(atPath: cliPath(home: home).path)
    }

    /// "MCP last call" on the Connect tab.
    public static func lastCall(_ date: Date?, now: Date) -> String {
        guard let date else { return "Not seen yet" }
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        switch seconds {
        case ..<60: return "just now"
        case ..<3600: return "\(seconds / 60) min ago"
        case ..<86400: return "\(seconds / 3600) h ago"
        default: return "\(seconds / 86400) d ago"
        }
    }

    /// Choose Repo Folder…: an absolute folder (after `~` expansion) holding mcp/relay_mcp.py.
    public static func isRepo(_ path: String, fileExists: (String) -> Bool) -> Bool {
        let folder = normalized(path)
        guard folder.hasPrefix("/") else { return false }
        return fileExists(folder + "/mcp/relay_mcp.py")
    }

    /// Trimmed, `~` expanded, no trailing slash.
    static func normalized(_ path: String) -> String {
        var text = (path.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
        while text.count > 1, text.hasSuffix("/") {
            text.removeLast()
        }
        return text
    }

    /// A zsh/bash double-quoted word: `"`, `\`, `$` and `` ` `` escaped.
    static func doubleQuoted(_ text: String) -> String {
        var out = "\""
        for character in text {
            if character == "\"" || character == "\\" || character == "$" || character == "`" {
                out.append("\\")
            }
            out.append(character)
        }
        out.append("\"")
        return out
    }
}
