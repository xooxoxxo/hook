import Foundation
import Testing
@testable import RelayCore

/// A fresh temp folder standing in for HOME; the caller removes it.
private func tempHome() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "relay-agents-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url.appending(path: ".claude"), withIntermediateDirectories: true)
    return url
}

private func write(_ text: String, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
}

private func json(_ url: URL) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
}

/// The commands of every UserPromptSubmit hook, in order.
private func promptCommands(_ object: [String: Any]) -> [String] {
    let groups = ((object["hooks"] as? [String: Any])?["UserPromptSubmit"] as? [[String: Any]]) ?? []
    return groups.flatMap { ($0["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String } }
}

@Suite struct AgentSetupTests {
    @Test func theHookGoesIntoAMissingSettingsFileWithNoBackup() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(!ConnectInfo.repliesHookInstalled(home: home))
        let result = try ConnectInfo.installRepliesHook(home: home)
        #expect(result == .added(backup: nil))
        let settings = try json(ConnectInfo.settingsPath(home: home))
        #expect(promptCommands(settings) == ["relay replies --new --hook"])
        let hook = try #require(((settings["hooks"] as? [String: Any])?["UserPromptSubmit"] as? [[String: Any]])?
            .first?["hooks"] as? [[String: Any]])
        #expect(hook.first?["type"] as? String == "command" && hook.first?["timeout"] as? Int == 5)
        #expect(ConnectInfo.repliesHookInstalled(home: home))
    }

    @Test func theHookMergeKeepsEverythingElseAndABackup() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let path = ConnectInfo.settingsPath(home: home)
        let before = """
        {"model": "opus", "permissions": {"allow": ["Bash(ls)"]},
         "hooks": {"UserPromptSubmit": [{"hooks": [{"type": "command", "command": "other-tool"}]}],
                   "Stop": [{"hooks": [{"type": "command", "command": "say done"}]}]}}
        """
        try write(before, to: path)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        let result = try ConnectInfo.installRepliesHook(home: home)
        let backup = path.resolvingSymlinksInPath().appendingPathExtension("bak")
        #expect(result == .added(backup: backup))
        #expect(try String(contentsOf: backup, encoding: .utf8) == before)
        let settings = try json(path)
        #expect(settings["model"] as? String == "opus")
        #expect((settings["permissions"] as? [String: Any])?["allow"] as? [String] == ["Bash(ls)"])
        #expect(promptCommands(settings) == ["other-tool", "relay replies --new --hook"])
        #expect(((settings["hooks"] as? [String: Any])?["Stop"] as? [Any])?.count == 1)
        let mode = try FileManager.default.attributesOfItem(atPath: path.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
    }

    @Test func theHookMergeIsIdempotent() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let path = ConnectInfo.settingsPath(home: home)
        try ConnectInfo.installRepliesHook(home: home)
        let once = try Data(contentsOf: path)
        #expect(try ConnectInfo.installRepliesHook(home: home) == .alreadyPresent)
        #expect(try Data(contentsOf: path) == once)
        #expect(!FileManager.default.fileExists(atPath: path.path + ".bak"))   // nothing written the second time
        #expect(promptCommands(try json(path)).count == 1)
    }

    @Test func aHandWrittenHookCountsAsPresent() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let path = ConnectInfo.settingsPath(home: home)
        try write(#"{"hooks": {"UserPromptSubmit": [{"hooks": [{"type": "command", "command": "~/.local/bin/hook replies --new --hook"}]}]}}"#, to: path)
        let before = try Data(contentsOf: path)
        #expect(ConnectInfo.repliesHookInstalled(home: home))
        #expect(try ConnectInfo.installRepliesHook(home: home) == .alreadyPresent)
        #expect(try Data(contentsOf: path) == before)
    }

    @Test func invalidJSONIsLeftUntouched() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let path = ConnectInfo.settingsPath(home: home)
        for text in [#"{"model": "opus","#, "[1, 2]", ""] {
            try write(text, to: path)
            #expect(throws: AgentSetupError.settingsInvalid("~/.claude/settings.json")) {
                try ConnectInfo.installRepliesHook(home: home)
            }
            #expect(try String(contentsOf: path, encoding: .utf8) == text)
            #expect(!FileManager.default.fileExists(atPath: path.path + ".bak"))
        }
    }

    @Test func hooksOfAnUnknownShapeAreLeftUntouched() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let path = ConnectInfo.settingsPath(home: home)
        for text in [#"{"hooks": "none"}"#, #"{"hooks": {"UserPromptSubmit": {"x": 1}}}"#] {
            try write(text, to: path)
            #expect(throws: AgentSetupError.settingsUnexpected("~/.claude/settings.json")) {
                try ConnectInfo.installRepliesHook(home: home)
            }
            #expect(try String(contentsOf: path, encoding: .utf8) == text)
        }
    }

    @Test func aSymlinkedSettingsFileIsWrittenThroughTheLink() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let target = home.appending(path: "dotfiles/settings.json")
        try write(#"{"model": "opus"}"#, to: target)
        try FileManager.default.createSymbolicLink(at: ConnectInfo.settingsPath(home: home), withDestinationURL: target)
        try ConnectInfo.installRepliesHook(home: home)
        let link = try FileManager.default.destinationOfSymbolicLink(atPath: ConnectInfo.settingsPath(home: home).path)
        #expect(link == target.path)                                       // still a link
        #expect(promptCommands(try json(target)) == ["relay replies --new --hook"])
        #expect(try json(target)["model"] as? String == "opus")
    }

    @Test func mcpRegisteredReadsTheUserServers() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(!ConnectInfo.mcpRegistered(home: home))
        try write(#"{"mcpServers": {"other": {}}}"#, to: ConnectInfo.claudeStatePath(home: home))
        #expect(!ConnectInfo.mcpRegistered(home: home))
        try write(#"{"mcpServers": {"relay": {"command": "python3"}}}"#, to: ConnectInfo.claudeStatePath(home: home))
        #expect(ConnectInfo.mcpRegistered(home: home))
        try write("not json", to: ConnectInfo.claudeStatePath(home: home))
        #expect(!ConnectInfo.mcpRegistered(home: home))
    }

    @Test func theMCPShellCommandAddsPathFallbacks() {
        let command = ConnectInfo.mcpShellCommand(repoPath: "/opt/src/relay")
        #expect(command.hasPrefix(#"PATH="$HOME/.local/bin:"#))
        #expect(command.hasSuffix(ConnectInfo.mcpCommand(repoPath: "/opt/src/relay")))
    }

    @Test func claudeMdCountsAsInstalledByItsHeading() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let repo = home.appending(path: "repo")
        try write("\n# Owner asks go to Hook\n\nBody.\n", to: repo.appending(path: "docs/claude-md-section.md"))
        #expect(!ConnectInfo.claudeMdInstalled(home: home, repoPath: repo.path))
        try write("# Mine\n\nOther notes.\n", to: ConnectInfo.claudeMdPath(home: home))
        #expect(!ConnectInfo.claudeMdInstalled(home: home, repoPath: repo.path))
        try write("# Mine\n\n# Owner asks go to Hook\nchanged body\n", to: ConnectInfo.claudeMdPath(home: home))
        #expect(ConnectInfo.claudeMdInstalled(home: home, repoPath: repo.path))
    }

    @Test func theDonationButtonNeedsAnHTTPSLink() {
        #expect(ConnectInfo.donationLink() == nil)                 // unset: the button stays hidden
        #expect(ConnectInfo.donationLink("") == nil)
        #expect(ConnectInfo.donationLink("http://example.com/support") == nil)
        #expect(ConnectInfo.donationLink(" https://example.com/support ")?.host() == "example.com")
    }
}

@Suite struct LoginShellTests {
    @Test func itRunsACommandAndKeepsTheOutput() async {
        let outcome = await LoginShell.run("echo hello; echo oops >&2", shell: "/bin/sh", timeout: 10)
        #expect(outcome.ok && outcome.output == "hello\noops")
    }

    @Test func aFailureKeepsItsStatusAndLastLine() async {
        let outcome = await LoginShell.run("echo first; echo 'it broke'; exit 3", shell: "/bin/sh", timeout: 10)
        #expect(!outcome.ok && outcome.status == 3 && !outcome.timedOut)
        #expect(LoginShell.failureLine(outcome) == "it broke")
        #expect(LoginShell.failureLine(.init(status: 127, output: "", timedOut: false)) == "The claude command wasn't found")
    }

    @Test func aHungCommandTimesOut() async {
        let start = Date()
        let outcome = await LoginShell.run("sleep 20", shell: "/bin/sh", timeout: 0.5)
        #expect(outcome.timedOut && !outcome.ok)
        #expect(Date().timeIntervalSince(start) < 10)
    }

    /// bash 3.2 runs `sleep` as a child (no exec of the last command), so stopping only the
    /// shell would leave sleep holding the pipe. The whole group is stopped instead.
    @Test func aTimeoutStopsWhatTheShellStarted() async throws {
        let start = Date()
        let outcome = await LoginShell.run("sleep 20 & echo $!; wait; true", shell: "/bin/bash", timeout: 0.5)
        #expect(outcome.timedOut && !outcome.ok)
        #expect(Date().timeIntervalSince(start) < 5)
        let sleeper = try #require(pid_t(outcome.output))
        var gone = false
        for _ in 0..<40 where !gone {
            gone = kill(sleeper, 0) == -1 && errno == ESRCH
            if !gone { try await Task.sleep(nanoseconds: 50_000_000) }
        }
        #expect(gone)
    }

    @Test func aChainedCommandUnderBashTimesOut() async {
        let start = Date()
        let outcome = await LoginShell.run("sleep 20; true", shell: "/bin/bash", timeout: 0.5)
        #expect(outcome.timedOut && !outcome.ok)
        #expect(Date().timeIntervalSince(start) < 5)
    }

    /// Something left behind that keeps the pipe open doesn't hold the result back.
    @Test func aLeftoverHoldingThePipeDoesntBlock() async {
        let start = Date()
        let outcome = await LoginShell.run("(sleep 20 &); echo x", shell: "/bin/sh", timeout: 0.5)
        #expect(outcome.ok && outcome.output == "x")
        #expect(Date().timeIntervalSince(start) < 5)
    }

    @Test func aMissingShellFails() async {
        let outcome = await LoginShell.run("true", shell: "/nonexistent/shell", timeout: 5)
        #expect(!outcome.ok && outcome.status == -1)
    }

    @Test func theShellIsTheUsersWhenAbsolute() {
        #expect(LoginShell.shell(environment: ["SHELL": "/bin/bash"]) == "/bin/bash")
        #expect(LoginShell.shell(environment: ["SHELL": "bash"]) == "/bin/zsh")
        #expect(LoginShell.shell(environment: [:]) == "/bin/zsh")
    }
}
