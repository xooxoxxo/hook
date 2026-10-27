import Foundation

/// The setup window's "Connect your agents" checks and the opt-in replies hook merge.
/// Reads (and, for the hook, writes) files under `home`, which the tests point at a temp folder.
public enum AgentSetupError: Error, Sendable, Equatable, LocalizedError {
    /// settings.json exists but isn't a JSON object; it was left alone.
    case settingsInvalid(String)
    /// settings.json holds `hooks` in a shape Hook doesn't know; it was left alone.
    case settingsUnexpected(String)

    public var errorDescription: String? {
        switch self {
        case .settingsInvalid(let path):
            return "\(path) isn't valid JSON, so it was left alone"
        case .settingsUnexpected(let path):
            return "\(path) has hooks Hook can't add to, so it was left alone"
        }
    }
}

extension ConnectInfo {
    /// The replies hook's command, as `hookSnippet()` shows it.
    public static let repliesHookCommand = "relay replies --new --hook"
    /// The hook's timeout in seconds, as `hookSnippet()` shows it.
    static let repliesHookTimeout = 5
    /// The Support Hook button's link. Empty hides the button.
    public static let donationURL = ""

    public static func donationLink(_ raw: String = donationURL) -> URL? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: text), url.scheme?.lowercased() == "https", url.host() != nil else { return nil }
        return url
    }

    // MARK: MCP server

    /// ~/.claude.json, where `claude mcp add --scope user` keeps user servers.
    public static func claudeStatePath(home: URL) -> URL {
        home.appending(path: ".claude.json")
    }

    /// The user-scope MCP server named relay is registered. False when the file is
    /// missing or unreadable.
    public static func mcpRegistered(home: URL) -> Bool {
        guard let object = jsonObject(at: claudeStatePath(home: home)),
              let servers = object["mcpServers"] as? [String: Any] else { return false }
        return servers["relay"] != nil
    }

    /// What the setup window runs in the login shell: install.sh's PATH fallbacks, then
    /// the registration. stdin is /dev/null, so it never waits on a prompt.
    public static func mcpShellCommand(repoPath: String) -> String {
        #"PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"; "# + mcpCommand(repoPath: repoPath)
    }

    // MARK: CLAUDE.md

    public static func claudeMdPath(home: URL) -> URL {
        home.appending(path: ".claude/CLAUDE.md")
    }

    /// ~/.claude/CLAUDE.md already holds the section's heading (its first non-blank line).
    public static func claudeMdInstalled(home: URL, repoPath: String) -> Bool {
        guard let section = claudeMdSection(repoPath: repoPath),
              let heading = section.split(separator: "\n").map({ $0.trimmingCharacters(in: .whitespaces) })
                .first(where: { !$0.isEmpty }),
              let text = try? String(contentsOf: claudeMdPath(home: home), encoding: .utf8) else { return false }
        return text.split(separator: "\n").contains { $0.trimmingCharacters(in: .whitespaces) == heading }
    }

    // MARK: Replies hook

    public static func settingsPath(home: URL) -> URL {
        home.appending(path: ".claude/settings.json")
    }

    /// settings.json has a UserPromptSubmit hook that runs `relay replies --new`.
    public static func repliesHookInstalled(home: URL) -> Bool {
        guard let object = jsonObject(at: settingsPath(home: home)) else { return false }
        return hasRepliesHook(object)
    }

    public enum HookMerge: Equatable, Sendable {
        /// The entry was added; `backup` is the copy of the file before, nil when there was none.
        case added(backup: URL?)
        /// The hook was already there; nothing was written.
        case alreadyPresent
    }

    /// Adds the replies hook to ~/.claude/settings.json. Keeps every other key and hook,
    /// copies the old file to settings.json.bak first, and replaces the file in one rename
    /// (through a symlink, the file it points to). Never rewrites a file it can't parse,
    /// and writes nothing when the hook is already there.
    @discardableResult
    public static func installRepliesHook(home: URL) throws -> HookMerge {
        let link = settingsPath(home: home)
        let fm = FileManager.default
        let exists = (try? fm.attributesOfItem(atPath: link.path)) != nil
        let path = exists ? link.resolvingSymlinksInPath() : link
        var object: [String: Any] = [:]
        if exists {
            guard let parsed = jsonObject(at: path) else { throw AgentSetupError.settingsInvalid(tilde(link, home: home)) }
            object = parsed
        }
        if hasRepliesHook(object) { return .alreadyPresent }
        let entry: [String: Any] = ["hooks": [[
            "type": "command", "command": repliesHookCommand, "timeout": repliesHookTimeout,
        ]]]
        var hooks: [String: Any]
        switch object["hooks"] {
        case nil: hooks = [:]
        case let existing as [String: Any]: hooks = existing
        default: throw AgentSetupError.settingsUnexpected(tilde(link, home: home))
        }
        var list: [Any]
        switch hooks["UserPromptSubmit"] {
        case nil: list = []
        case let existing as [Any]: list = existing
        default: throw AgentSetupError.settingsUnexpected(tilde(link, home: home))
        }
        list.append(entry)
        hooks["UserPromptSubmit"] = list
        object["hooks"] = hooks
        var data = try JSONSerialization.data(
            withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        data.append(0x0A)

        var backup: URL?
        let permissions = (try? fm.attributesOfItem(atPath: path.path))?[.posixPermissions]
        if exists {
            let bak = path.appendingPathExtension("bak")
            let tmp = path.deletingLastPathComponent().appending(path: ".\(path.lastPathComponent).bak.\(UUID().uuidString)")
            try fm.copyItem(at: path, to: tmp)
            if (try? fm.attributesOfItem(atPath: bak.path)) != nil { try fm.removeItem(at: bak) }
            try fm.moveItem(at: tmp, to: bak)
            backup = bak
        } else {
            try fm.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        try data.write(to: path, options: .atomic)
        if let permissions { try? fm.setAttributes([.posixPermissions: permissions], ofItemAtPath: path.path) }
        return .added(backup: backup)
    }

    static func hasRepliesHook(_ object: [String: Any]) -> Bool {
        guard let hooks = object["hooks"] as? [String: Any],
              let list = hooks["UserPromptSubmit"] as? [Any] else { return false }
        return list.contains { item in
            guard let group = item as? [String: Any], let inner = group["hooks"] as? [Any] else { return false }
            return inner.contains { hook in
                guard let command = (hook as? [String: Any])?["command"] as? String else { return false }
                return command.contains("relay replies --new") || command.contains("hook replies --new")
            }
        }
    }

    /// The JSON object in `url`, or nil when it is missing, unreadable or not an object.
    static func jsonObject(at url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url),
              let parsed = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return parsed as? [String: Any]
    }

    static func tilde(_ url: URL, home: URL) -> String {
        TildePath.abbreviate(url.path, home: home.path)
    }
}
