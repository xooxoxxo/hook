import Testing
@testable import RelayUI

@Suite @MainActor struct CodeComponentTests {
    @Test func copyTitles() {
        #expect(CodeBlock.copyTitle(copied: false, hidden: false) == "Copy")
        #expect(CodeBlock.copyTitle(copied: false, hidden: true) == "Copy as Shown")
        #expect(CodeBlock.copyTitle(copied: true, hidden: true) == "Copied")
    }

    @Test func codeLabel() {
        #expect(CodeBlock.codeLabel(lang: "bash") == "Command, bash")
        #expect(CodeBlock.codeLabel(lang: nil) == "Command")
        #expect(CodeBlock.codeLabel(lang: "b\na") == "Command, b⟨U+000A⟩a")
    }

    @Test func shownTextRevealsHiddenCharacters() {
        #expect(CodeBlock.shown("echo token\u{200B}-ok") == (text: "echo token⟨U+200B⟩-ok", hidden: true))
        #expect(CodeBlock.shown("ls").hidden == false)
        #expect(CodeBlock.warning == "Hidden characters shown as ⟨U+…⟩. Check before running.")
    }

    @Test func linkSentences() {
        #expect(OpenLink.accessibilityText("Open example.com") == "Open example.com, link")
        #expect(ExpectLine.text("token-ok") == "Expect: token-ok")
        #expect(ExpectLine.text("a\u{202E}b") == "Expect: a⟨U+202E⟩b")
    }
}
