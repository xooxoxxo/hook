import Testing
@testable import RelayCore

@Suite struct CodeWrapTests {
    @Test func plainTextWraps() {
        #expect(CodeWrap.shouldWrap(lang: nil))
        #expect(CodeWrap.shouldWrap(lang: ""))
        #expect(CodeWrap.shouldWrap(lang: "  "))
        #expect(CodeWrap.shouldWrap(lang: "text"))
        #expect(CodeWrap.shouldWrap(lang: "TEXT"))
        #expect(CodeWrap.shouldWrap(lang: "Text"))
        #expect(CodeWrap.shouldWrap(lang: " text "))
    }

    @Test func languagesStayExact() {
        for lang in ["bash", "shell", "json", "python", "texts", "plaintext", "txt"] {
            #expect(!CodeWrap.shouldWrap(lang: lang), "\(lang)")
        }
    }
}
