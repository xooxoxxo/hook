import Foundation

/// The Hook repo folder and the MCP server's last call, for Settings › Agents and the setup
/// window. Pure.
public enum ConnectInfo {
    /// "MCP last call".
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
    public static func normalized(_ path: String) -> String {
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
