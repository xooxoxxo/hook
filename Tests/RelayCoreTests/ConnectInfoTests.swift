import Foundation
import Testing
@testable import RelayCore

/// A fresh folder under the temp directory; the caller removes it.
private func tempFolder() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "relay-connect-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// root/home (empty) and root/repo, with root/repo/skill/instructables when `withSkill`.
private func sandbox(withSkill: Bool = true) throws -> (root: URL, home: URL, repo: URL) {
    let root = try tempFolder()
    let home = root.appending(path: "home", directoryHint: .isDirectory)
    let repo = root.appending(path: "repo", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
    if withSkill {
        try FileManager.default.createDirectory(
            at: repo.appending(path: "skill/instructables", directoryHint: .isDirectory),
            withIntermediateDirectories: true)
    }
    return (root, home, repo)
}

@Suite struct ConnectInfoTests {
    @Test func mcpCommandPointsAtTheRepo() {
        #expect(ConnectInfo.mcpCommand(repoPath: "/opt/src/relay")
                == #"claude mcp add --scope user relay -- python3 "/opt/src/relay/mcp/relay_mcp.py""#)
        #expect(ConnectInfo.mcpCommand(repoPath: "/opt/src/relay/") == ConnectInfo.mcpCommand(repoPath: "/opt/src/relay"))
        #expect(ConnectInfo.mcpCommand(repoPath: " /opt/src/relay\n") == ConnectInfo.mcpCommand(repoPath: "/opt/src/relay"))
    }

    @Test func mcpCommandEscapesShellCharacters() {
        #expect(ConnectInfo.mcpCommand(repoPath: #"/opt/my "src"/$HOME`x`\relay"#)
                == #"claude mcp add --scope user relay -- python3 "/opt/my \"src\"/\$HOME\`x\`\\relay/mcp/relay_mcp.py""#)
    }

    @Test func cliExampleIsAValidInstructable() throws {
        let lines = ConnectInfo.cliExample().components(separatedBy: "\n")
        #expect(lines.count == 3)
        #expect(lines.first == "relay post Acme --json - <<'EOF'")
        #expect(lines.last == "EOF")
        #expect(lines[1] == ConnectInfo.exampleInstructable)
        let value = try JSONValue.parse(Data(lines[1].utf8))
        switch Validator.validate(value) {
        case .success:
            break
        case .failure(let failure):
            Issue.record("the CLI example is not a valid instructable: \(failure.errors)")
        }
    }

    @Test func hookSnippetIsTheRepliesHookPrettyPrinted() throws {
        let expected = try JSONValue.parse(Data(
            #"{"hooks": {"UserPromptSubmit": [{"hooks": [{"type": "command", "command": "relay replies --new --hook", "timeout": 5}]}]}}"#.utf8))
        let snippet = ConnectInfo.hookSnippet()
        #expect(try JSONValue.parse(Data(snippet.utf8)) == expected)
        #expect(snippet.hasPrefix("{\n  \"hooks\": {"))
        #expect(snippet.hasSuffix("\n}"))
    }

    @Test func claudeMdSectionReadsTheRepoFile() throws {
        let repo = try tempFolder()
        defer { try? FileManager.default.removeItem(at: repo) }
        #expect(ConnectInfo.claudeMdSection(repoPath: repo.path) == nil)

        let docs = repo.appending(path: "docs", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        let file = docs.appending(path: "claude-md-section.md")
        try Data("  \n".utf8).write(to: file)
        #expect(ConnectInfo.claudeMdSection(repoPath: repo.path) == nil)

        let text = "## Owner asks go to Relay\n\nSend one instructable with relay_post.\n"
        try Data(text.utf8).write(to: file)
        #expect(ConnectInfo.claudeMdSection(repoPath: repo.path) == text)
    }

    @Test func skillIsMissingThenInstalled() throws {
        let (root, home, repo) = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(ConnectInfo.skillState(home: home, repoPath: repo.path) == .missing)

        try ConnectInfo.installSkill(home: home, repoPath: repo.path)
        #expect(ConnectInfo.skillState(home: home, repoPath: repo.path) == .installed)
        let link = ConnectInfo.skillPath(home: home).path
        #expect(link == home.appending(path: ".claude/skills/instructables").path)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link)
                == repo.appending(path: "skill/instructables").path)

        // Installing again refuses and keeps the link.
        #expect(throws: ConnectInfoError.skillPresent(link)) {
            try ConnectInfo.installSkill(home: home, repoPath: repo.path)
        }
        #expect(ConnectInfo.skillState(home: home, repoPath: repo.path) == .installed)
    }

    @Test func aLinkToAnotherSkillIsElsewhereAndLeftAlone() throws {
        let (root, home, repo) = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let other = root.appending(path: "other-skill", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let link = ConnectInfo.skillPath(home: home)
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: other.path)

        #expect(ConnectInfo.skillState(home: home, repoPath: repo.path) == .elsewhere(other.path))
        #expect(throws: ConnectInfoError.skillPresent(link.path)) {
            try ConnectInfo.installSkill(home: home, repoPath: repo.path)
        }
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == other.path)
    }

    @Test func aDanglingLinkIsElsewhere() throws {
        let (root, home, repo) = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let gone = root.appending(path: "gone").path
        let link = ConnectInfo.skillPath(home: home)
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: gone)

        #expect(ConnectInfo.skillState(home: home, repoPath: repo.path) == .elsewhere(gone))
        #expect(throws: ConnectInfoError.skillPresent(link.path)) {
            try ConnectInfo.installSkill(home: home, repoPath: repo.path)
        }
    }

    @Test func aRealFolderAtTheSkillPathIsElsewhere() throws {
        let (root, home, repo) = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let link = ConnectInfo.skillPath(home: home)
        try FileManager.default.createDirectory(at: link, withIntermediateDirectories: true)

        #expect(ConnectInfo.skillState(home: home, repoPath: repo.path) == .elsewhere(link.path))
    }

    @Test func installRefusesWithoutTheRepoSkill() throws {
        let (root, home, repo) = try sandbox(withSkill: false)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(throws: ConnectInfoError.skillSourceMissing(repo.appending(path: "skill/instructables").path)) {
            try ConnectInfo.installSkill(home: home, repoPath: repo.path)
        }
        #expect(ConnectInfo.skillState(home: home, repoPath: repo.path) == .missing)
        #expect(!FileManager.default.fileExists(atPath: home.appending(path: ".claude").path))
    }

    @Test func cliInstalledNeedsALinkThatResolves() throws {
        let (root, home, _) = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(!ConnectInfo.cliInstalled(home: home))

        let shim = root.appending(path: "relay-shim")
        try Data("#!/bin/sh\n".utf8).write(to: shim)
        let bin = home.appending(path: ".local/bin", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: ConnectInfo.cliPath(home: home).path, withDestinationPath: shim.path)
        #expect(ConnectInfo.cliPath(home: home).path == home.appending(path: ".local/bin/relay").path)
        #expect(ConnectInfo.cliInstalled(home: home))

        try FileManager.default.removeItem(at: shim)
        #expect(!ConnectInfo.cliInstalled(home: home))
    }

    @Test func lastCallText() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(ConnectInfo.lastCall(nil, now: now) == "Not seen yet")
        #expect(ConnectInfo.lastCall(now - 20, now: now) == "just now")
        #expect(ConnectInfo.lastCall(now - 180, now: now) == "3 min ago")
        #expect(ConnectInfo.lastCall(now - 7200, now: now) == "2 h ago")
        #expect(ConnectInfo.lastCall(now - 3 * 86400, now: now) == "3 d ago")
        #expect(ConnectInfo.lastCall(now + 30, now: now) == "just now")   // a clock step backwards
    }

    @Test func aRepoIsAnAbsoluteFolderWithTheMCPServer() {
        let present: Set<String> = ["/opt/src/relay/mcp/relay_mcp.py"]
        let exists: (String) -> Bool = { present.contains($0) }
        #expect(ConnectInfo.isRepo("/opt/src/relay", fileExists: exists))
        #expect(ConnectInfo.isRepo("/opt/src/relay/", fileExists: exists))
        #expect(ConnectInfo.isRepo("  /opt/src/relay \n", fileExists: exists))
        #expect(!ConnectInfo.isRepo("/opt/src/other", fileExists: exists))
        #expect(!ConnectInfo.isRepo("relay", fileExists: { _ in true }))          // relative
        #expect(!ConnectInfo.isRepo("", fileExists: { _ in true }))
    }

    @Test func aTildeRepoPathIsExpandedFirst() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        #expect(ConnectInfo.isRepo("~/src/relay", fileExists: { $0 == home + "/src/relay/mcp/relay_mcp.py" }))
    }
}
