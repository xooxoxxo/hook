import Testing
@testable import RelayCore

@Suite struct LinkDisplayTests {
    @Test func webMeansHTTPWithAHost() {
        #expect(LinkDisplay.isWeb("https://www.example.com/oauth/apps"))
        #expect(LinkDisplay.isWeb("HTTP://example.com"))
        #expect(!LinkDisplay.isWeb("ftp://files.example.com/brief.pdf"))
        #expect(!LinkDisplay.isWeb("https://"))
        #expect(!LinkDisplay.isWeb("javascript:alert(1)"))
        #expect(!LinkDisplay.isWeb("example.com"))
    }

    @Test func hostDropsWWW() {
        #expect(LinkDisplay.host("https://www.example.com/x") == "example.com")
        #expect(LinkDisplay.host("https://api.example.org/apps") == "api.example.org")
        #expect(LinkDisplay.host("not a url") == nil)
    }

    @Test func stepTitles() {
        #expect(LinkDisplay.stepTitle("https://www.example.com/oauth/apps") == "Open example.com")
        #expect(LinkDisplay.stepTitle("https://xn--bcher-kva.example.com/apps") == "Open xn--bcher-kva.example.com ⚠︎ non-ASCII host")
        #expect(LinkDisplay.stepTitle("ftp://files.example.com/brief.pdf") == nil)
    }

    @Test func linkTitles() {
        #expect(LinkDisplay.linkTitle(label: "API docs", url: "https://api.example.com/v2/docs") == "API docs · api.example.com")
        #expect(LinkDisplay.linkTitle(label: "Run\nbook", url: "https://xn--bcher-kva.example/x")
            == "Run⟨U+000A⟩book · xn--bcher-kva.example ⚠︎ non-ASCII host")
    }

    @Test func refusedTexts() {
        #expect(LinkDisplay.refusedText(label: nil) == "Link not shown: only http and https open here")
        #expect(LinkDisplay.refusedText(label: "Brief") == "Brief (not a web address)")
        #expect(LinkDisplay.refusedText(label: "a\tb") == "a⟨U+0009⟩b (not a web address)")
    }
}
