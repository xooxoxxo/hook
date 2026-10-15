import Foundation
import Testing
@testable import RelayCore

private let session = "5f633ed3-a328-412b-bf54-5b1e0c16a093"

private func origin(host: String? = "build-mac", cwd: String? = "/work/acme", session: String? = session) -> AskOrigin? {
    AskOrigin(from: Origin(session: session, host: host, cwd: cwd))
}

@Suite struct AskOriginTests {
    @Test func plainPath() throws {
        let o = try #require(origin())
        #expect(o.host == "build-mac")
        #expect(o.cwd == "/work/acme")
        #expect(o.session == session)
        #expect(o.folder == "acme")
        #expect(o.shortSession == "5f633ed3")
        #expect(o.summary == "acme · build-mac · 5f633ed3")
        #expect(o.resumeCommand == "cd '/work/acme' && claude --resume \(session)")
    }

    @Test func helpLinesInFullAndInOrder() throws {
        let o = try #require(origin())
        #expect(o.helpLines == ["Folder: /work/acme", "Host: build-mac", "Session: \(session)"])
        let hostOnly = try #require(origin(cwd: nil, session: nil))
        #expect(hostOnly.helpLines == ["Host: build-mac"])
        let badSession = try #require(origin(session: "x"))
        #expect(badSession.helpLines == ["Folder: /work/acme", "Host: build-mac"])
    }

    @Test func pathWithSpaces() throws {
        let o = try #require(origin(cwd: "  /Users/me/My Projects/site  "))
        #expect(o.cwd == "/Users/me/My Projects/site")
        #expect(o.folder == "site")
        #expect(o.resumeCommand == "cd '/Users/me/My Projects/site' && claude --resume \(session)")
    }

    @Test func pathWithASingleQuote() throws {
        let o = try #require(origin(cwd: "/work/it's here/'x'"))
        #expect(o.resumeCommand == #"cd '/work/it'\''s here/'\''x'\''' && claude --resume "# + session)
        #expect(o.folder == "'x'")
    }

    @Test func relativePathGivesNoCommand() throws {
        let o = try #require(origin(cwd: "work/acme"))
        #expect(o.folder == "acme")
        #expect(o.resumeCommand == nil)
        #expect(try #require(origin(cwd: "~/acme")).resumeCommand == nil)
    }

    @Test func controlOrHiddenCharactersGiveNoCommand() throws {
        for cwd in ["/work/a\nb", "/work/a\u{200B}b", "/work/a\tb", "/work/a\u{202E}b", "/work/a\u{7F}b",
                    "/work/a\u{200D}b", "/work/a\rb"] {
            let o = try #require(origin(cwd: cwd))
            #expect(o.resumeCommand == nil, "\(cwd.unicodeScalars.map(\.value))")
            #expect(o.session == session)
        }
    }

    @Test func overlongPathGivesNoCommand() throws {
        let ok = "/" + String(repeating: "a", count: 1023)
        #expect(try #require(origin(cwd: ok)).resumeCommand != nil)
        #expect(try #require(origin(cwd: ok + "a")).resumeCommand == nil)
    }

    @Test func invalidSessionGivesNoSessionAndNoCommand() throws {
        for bad in ["../x", "abc", String(repeating: "a", count: 65), "a;rm", "-abcdefgh", "abcdefg ", "abcdefgh\n",
                    "abcdéfgh", ""] {
            let o = try #require(origin(session: bad))
            #expect(o.session == nil, "\(bad)")
            #expect(o.shortSession == nil)
            #expect(o.resumeCommand == nil)
            #expect(o.summary == "acme · build-mac")
        }
        #expect(origin(session: String(repeating: "a", count: 64))?.session != nil)
        #expect(origin(session: "abcdefgh")?.session == "abcdefgh")
        #expect(origin(session: "abcdefgh")?.shortSession == "abcdefgh")
    }

    @Test func missingHostOrCwdSummaries() throws {
        #expect(try #require(origin(host: nil)).summary == "acme · 5f633ed3")
        #expect(try #require(origin(host: "  ")).host == nil)
        let noCwd = try #require(origin(cwd: nil))
        #expect(noCwd.summary == "build-mac · 5f633ed3")
        #expect(noCwd.folder == nil)
        #expect(noCwd.resumeCommand == nil)
        #expect(try #require(origin(host: nil, cwd: nil)).summary == "5f633ed3")
        #expect(try #require(origin(cwd: "/")).folder == "/")
        #expect(try #require(origin(cwd: "/work/acme/")).folder == "acme")
        #expect(try #require(origin(session: nil)).summary == "acme · build-mac")
    }

    @Test func nilCases() {
        #expect(AskOrigin(from: nil) == nil)
        #expect(AskOrigin(from: Origin()) == nil)
        #expect(origin(host: " ", cwd: "\n", session: nil) == nil)
        #expect(origin(host: nil, cwd: nil, session: "abc") == nil)
    }
}
