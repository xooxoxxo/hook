import Testing
@testable import RelayCore

@Test func bidiOverrideInCodeIsRevealed() {
    let shown = Sanitize.reveal("echo \u{202E}txt.exe", as: .code)
    #expect(shown.hidden)
    #expect(shown.text == "echo ⟨U+202E⟩txt.exe")
}

@Test func tagCharacterAndZeroWidthSpaceAreRevealed() {
    let shown = Sanitize.reveal("a\u{E0041}b\u{200B}c", as: .prose)
    #expect(shown.hidden)
    #expect(shown.text == "a⟨U+E0041⟩b⟨U+200B⟩c")
}

@Test func zwjIsKeptInProseButRevealedInCode() {
    let family = "👨\u{200D}👩\u{200D}👧"
    #expect(Sanitize.reveal(family, as: .prose) == (family, false))
    #expect(Sanitize.reveal("rm\u{200D} -rf", as: .code) == ("rm⟨U+200D⟩ -rf", true))
}

@Test func copyTextTrimsTrailingNewline() {
    #expect(Sanitize.copyText("brew install jq\n") == "brew install jq")
    #expect(Sanitize.copyText("a\n\tb  \n\n") == "a\n\tb")
}

@Test func carriageReturnIsRevealed() {
    #expect(Sanitize.reveal("ok\rrm -rf ~", as: .code) == ("ok⟨U+000D⟩rm -rf ~", true))
    #expect(Sanitize.revealLine("a\nb\tc") == "a⟨U+000A⟩b⟨U+0009⟩c")
}

@Test func brailleBlankIsNotHidden() {
    #expect(Sanitize.reveal("a\u{2800}b", as: .code) == ("a\u{2800}b", false))
}

@Test func languageTagAndUnassignedSpecialAreRevealed() {
    #expect(Sanitize.reveal("a\u{E0001}b\u{FFF0}c", as: .prose) == ("a⟨U+E0001⟩b⟨U+FFF0⟩c", true))
}
