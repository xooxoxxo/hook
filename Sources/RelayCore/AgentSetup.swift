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
    /// The Support Hook button's link on the setup window's last page. Empty, or anything
    /// that isn't an https link, hides the button.
    public static let donationURL = "https://ko-fi.com/xo-vision"

    public static func donationLink(_ raw: String = donationURL) -> URL? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: text), url.scheme?.lowercased() == "https", url.host() != nil else { return nil }
        return url
    }

    // MARK: Checks

    /// What the setup window's agents page shows as done.
    public struct AgentChecks: Equatable, Sendable {
        public var mcpRegistered: Bool
        public var hookInstalled: Bool
        public var claudeMdInstalled: Bool

        public init(mcpRegistered: Bool = false, hookInstalled: Bool = false, claudeMdInstalled: Bool = false) {
            self.mcpRegistered = mcpRegistered
            self.hookInstalled = hookInstalled
            self.claudeMdInstalled = claudeMdInstalled
        }
    }

    /// Reads ~/.claude.json (which can be large), settings.json and CLAUDE.md. Blocking file
    /// work: the app calls it off the main actor.
    public static func agentChecks(home: URL, repoPath: String?) -> AgentChecks {
        AgentChecks(mcpRegistered: mcpRegistered(home: home), hookInstalled: repliesHookInstalled(home: home),
                    claudeMdInstalled: repoPath.map { claudeMdInstalled(home: home, repoPath: $0) } ?? false)
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

    /// Adds the replies hook to ~/.claude/settings.json. Keeps every other key and hook, in
    /// their order and as written (OrderedJSON), though the file is rewritten as JSON with
    /// two-space indents. Copies the old file first to settings.json.bak, or, when that is
    /// taken, settings.json.bak-YYYYMMDD-HHMMSS (`backupURL`); an old backup is never
    /// overwritten. Replaces the file in one rename (through a symlink, the file it points
    /// to). Never rewrites a file it can't parse, and writes nothing when the hook is there.
    /// `now` and `timeZone` name a stamped backup; tests pass both so the name is fixed.
    @discardableResult
    public static func installRepliesHook(home: URL, now: Date = Date(),
                                          timeZone: TimeZone = .current) throws -> HookMerge {
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
        // The shape check on the parsed object; the edit on the ordered copy.
        let hooksValue = object["hooks"]
        guard hooksValue == nil || hooksValue is [String: Any] else {
            throw AgentSetupError.settingsUnexpected(tilde(link, home: home))
        }
        let listValue = (hooksValue as? [String: Any])?["UserPromptSubmit"]
        guard listValue == nil || listValue is [Any] else {
            throw AgentSetupError.settingsUnexpected(tilde(link, home: home))
        }
        var document = OrderedJSON.object([])
        if exists {
            guard let parsed = try? OrderedJSON.parse(Data(contentsOf: path)) else {
                throw AgentSetupError.settingsInvalid(tilde(link, home: home))
            }
            document = parsed
        }
        var hooks = document.member("hooks") ?? .object([])
        var list: [OrderedJSON] = []
        if case .array(let items)? = hooks.member("UserPromptSubmit") { list = items }
        list.append(repliesHookEntry)
        hooks.setMember("UserPromptSubmit", .array(list))
        document.setMember("hooks", hooks)
        let data = Data((document.text() + "\n").utf8)

        var backup: URL?
        let permissions = (try? fm.attributesOfItem(atPath: path.path))?[.posixPermissions]
        if exists {
            let bak = backupURL(for: path, now: now, timeZone: timeZone)
            let tmp = path.deletingLastPathComponent().appending(path: ".\(path.lastPathComponent).bak.\(UUID().uuidString)")
            try fm.copyItem(at: path, to: tmp)
            do {
                try fm.moveItem(at: tmp, to: bak)
            } catch {
                try? fm.removeItem(at: tmp)
                throw error
            }
            backup = bak
        } else {
            try fm.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        try data.write(to: path, options: .atomic)
        if let permissions { try? fm.setAttributes([.posixPermissions: permissions], ofItemAtPath: path.path) }
        return .added(backup: backup)
    }

    /// `{"hooks": [{"type": "command", "command": …, "timeout": 5}]}`, keys in that order.
    static var repliesHookEntry: OrderedJSON {
        .object([.init(key: "\"hooks\"", value: .array([.object([
            .init(key: "\"type\"", value: .scalar("\"command\"")),
            .init(key: "\"command\"", value: OrderedJSON.string(repliesHookCommand)),
            .init(key: "\"timeout\"", value: .scalar(String(repliesHookTimeout))),
        ])]))])
    }

    /// Where the old settings file goes: `<name>.bak` when that is free, else
    /// `<name>.bak-YYYYMMDD-HHMMSS` in local time (as install.sh names a set-aside config),
    /// with `-2`, `-3`… when even that is taken.
    public static func backupURL(for path: URL, now: Date, timeZone: TimeZone = .current) -> URL {
        let fm = FileManager.default
        let taken = { (url: URL) in (try? fm.attributesOfItem(atPath: url.path)) != nil }
        let plain = path.appendingPathExtension("bak")
        guard taken(plain) else { return plain }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamped = path.deletingLastPathComponent()
            .appending(path: path.lastPathComponent + ".bak-" + formatter.string(from: now))
        var candidate = stamped
        var count = 2
        while taken(candidate) {
            candidate = stamped.deletingLastPathComponent().appending(path: stamped.lastPathComponent + "-\(count)")
            count += 1
        }
        return candidate
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
