import Foundation
import Testing
@testable import RelayCore

@Suite struct ConnectInfoTests {
    @Test func doubleQuotedEscapesShellCharacters() {
        #expect(ConnectInfo.doubleQuoted(#"/opt/my "src"/$HOME`x`\relay"#) == #""/opt/my \"src\"/\$HOME\`x\`\\relay""#)
        #expect(ConnectInfo.doubleQuoted("plain") == "\"plain\"")
    }

    @Test func normalizedTrimsAndDropsTrailingSlashes() {
        #expect(ConnectInfo.normalized(" /opt/src/relay//\n") == "/opt/src/relay")
        #expect(ConnectInfo.normalized("/") == "/")
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
