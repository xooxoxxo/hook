import Testing
@testable import RelayCore

/// The viewer's front matter (spec "Viewer: front matter"): the YAML between an opening and a
/// closing `---` is read off the body; malformed, it is kept raw; absent, nothing changes.
@Suite struct FrontMatterTests {
    @Test func validFrontMatterIsReadOffTheBody() {
        let text = """
        ---
        tags: [project/relay, spec]
        created: 2026-11-04
        status: "picks in"
        related: "[[Hook - 0.12]]"
        aliases:
          - Hook 0.14
          - Step report
        ---

        # Hook 0.14
        """
        let split = FrontMatter.split(text)
        #expect(split.body == "\n# Hook 0.14")
        guard case .fields(let fields) = split.front else { Issue.record("not read: \(split.front)"); return }
        #expect(fields.map(\.key) == ["tags", "created", "status", "related", "aliases"])
        #expect(fields[0].value == .list(["project/relay", "spec"]))
        #expect(fields[1].value == .text("2026-11-04"))
        #expect(fields[2].value == .text("picks in"))
        #expect(fields[3].value == .text("[[Hook - 0.12]]"))
        #expect(fields[4].value == .list(["Hook 0.14", "Step report"]))
    }

    /// The strip: tags as chips, created and status inline, the rest behind "N more".
    @Test func theStripSortsTheKeys() {
        let split = FrontMatter.split("---\nstatus: draft\ntags: a, b\nowner: me\ncreated: 2026-11-04\nrelated: x\n---\nbody")
        let strip = FrontMatter.Strip(split.front)
        #expect(strip?.tags == ["a", "b"])
        #expect(strip?.inline.map(\.key) == ["created", "status"])
        #expect(strip?.more.map(\.key) == ["owner", "related"])
        #expect(strip?.moreTitle == "2 more")
        #expect(split.body == "body")
    }

    @Test func malformedFrontMatterStaysRawAndOutOfTheBody() {
        let text = "---\ntags: [a, b\nthis line is not yaml\n---\n# Title\n"
        let split = FrontMatter.split(text)
        #expect(split.front == .malformed("tags: [a, b\nthis line is not yaml"))
        #expect(split.body == "# Title\n")
        #expect(FrontMatter.Strip(split.front) == nil)
    }

    @Test func absentFrontMatterChangesNothing() {
        for text in ["# Title\n\n---\n\nmore", "", "--- not a fence\nx\n---\n", "---\nno closing fence\n"] {
            let split = FrontMatter.split(text)
            #expect(split.front == .absent, "\(text)")
            #expect(split.body == text)
        }
    }

    @Test func emptyFrontMatterHasNoStrip() {
        let split = FrontMatter.split("---\n---\nbody")
        #expect(split.front == .fields([]))
        #expect(split.body == "body")
        #expect(FrontMatter.Strip(split.front) == nil)
    }

    @Test func crlfCommentsAndBlockText() {
        let split = FrontMatter.split("---\r\n# a comment\r\nsummary: |\r\n  two\r\n  lines\r\nstatus: ok\r\n---\r\nbody")
        guard case .fields(let fields) = split.front else { Issue.record("not read"); return }
        #expect(fields.map(\.key) == ["summary", "status"])
        #expect(fields[0].value == .text("two\nlines"))
        #expect(split.body == "body")
    }
}
