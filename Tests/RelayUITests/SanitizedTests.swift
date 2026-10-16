import RelayCore
import Testing
@testable import RelayUI

@Suite struct SanitizedTests {
    @Test func lineRevealsNewlinesTabsAndHiddenCharacters() {
        #expect(line("a\nb\tc") == "a⟨U+000A⟩b⟨U+0009⟩c")
        #expect(line("x\u{202E}y") == "x⟨U+202E⟩y")
        #expect(line("Acme") == "Acme")
    }

    @Test func proseKeepsNewlinesAndRevealsHiddenCharacters() {
        #expect(prose("one\ntwo") == "one\ntwo")
        #expect(prose("a\u{200B}b") == "a⟨U+200B⟩b")
        #expect(prose("👩‍💻") == "👩‍💻")
    }

    @Test func helpersMatchRelayCore() {
        let raw = "t\u{2066}x\ny"
        #expect(line(raw) == Sanitize.revealLine(raw))
        #expect(prose(raw) == Sanitize.reveal(raw, as: .prose).text)
    }
}
