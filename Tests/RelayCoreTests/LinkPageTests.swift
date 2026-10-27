import CryptoKit
import Foundation
import Testing
@testable import RelayCore

private func text(_ response: HTTPResponse) -> String {
    String(decoding: response.body, as: UTF8.self)
}

@Test func linkPageBodyIsTheSameForKnownAndUnknownIds() {
    let found = LinkPage.response(status: 200)
    let missing = LinkPage.response(status: 404)
    #expect(found.status == 200)
    #expect(missing.status == 404)
    #expect(found.body == missing.body)
    #expect(found.headers == missing.headers)
    #expect(!text(found).contains("/i/"))
}

@Test func linkPageCarriesTitleTextAndClose() {
    let body = text(LinkPage.response(status: 200))
    #expect(body.contains("<title>Hook</title>"))
    #expect(body.contains("Handed to Hook"))
    #expect(body.contains("This tab closes by itself."))
    #expect(body.contains("You can close this tab."))
    #expect(body.contains("window.close()"))
    #expect(body.contains(#"<meta name="color-scheme" content="light dark">"#))
    #expect(body.contains(#"name="viewport""#))
    #expect(body.contains("prefers-reduced-motion"))
    #expect(body.contains("prefers-color-scheme"))
    #expect(!body.contains("<img"))
}

@Test func linkPageCSPHashMatchesTheInlineScript() throws {
    let body = text(LinkPage.response(status: 200))
    let open = try #require(body.range(of: "<script>"))
    let close = try #require(body.range(of: "</script>", range: open.upperBound..<body.endIndex))
    let script = String(body[open.upperBound..<close.lowerBound])
    let hash = Data(SHA256.hash(data: Data(script.utf8))).base64EncodedString()
    let csp = try #require(LinkPage.response(status: 200).headers["Content-Security-Policy"])
    #expect(csp.contains("script-src 'sha256-\(hash)'"))
    #expect(body.components(separatedBy: "<script").count == 2)
}

@Test func linkPageSendsEveryRequiredHeader() {
    let headers = LinkPage.response(status: 404).headers
    #expect(headers["Content-Type"] == "text/html; charset=utf-8")
    #expect(headers["Cache-Control"] == "no-store")
    #expect(headers["X-Content-Type-Options"] == "nosniff")
    #expect(headers["Referrer-Policy"] == "no-referrer")
    let csp = headers["Content-Security-Policy"] ?? ""
    for part in [
        "default-src 'none'", "style-src 'unsafe-inline'", "img-src data:",
        "base-uri 'none'", "form-action 'none'", "frame-ancestors 'none'",
    ] {
        #expect(csp.contains(part), "missing \(part)")
    }
}

@Suite struct LinkPageTests {
    /// Screen readers hear the note change to "You can close this tab."
    @Test func theNoteIsAStatusRegion() {
        let body = String(decoding: LinkPage.response(status: 200).body, as: UTF8.self)
        #expect(body.contains(#"<p id="note" role="status">This tab closes by itself.</p>"#))
        #expect(body.components(separatedBy: #"id="note""#).count == 2)
    }
}
