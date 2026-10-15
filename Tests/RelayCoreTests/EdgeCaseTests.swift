import Testing
@testable import RelayCore

// Edge cases from the QA probe.

private let edgeID = "6f1c2b0e-8a1d-4c55-9a77-0d2f3c4b5a61"

/// Host names are case-insensitive (RFC 9110 §7.2) and browsers send them
/// lowercased, so an uppercase loopback name is the same loopback host. The
/// DNS-rebinding guard is about the name, not its case.
@Test func uppercaseLocalhostIsTheSameHost() {
    let d = LinkPolicy.decide(method: "GET", path: "/i/" + edgeID, headers: ["Host": "LOCALHOST:47823"], port: 47823)
    #expect(d == .open(id: edgeID))
}

@Test func queryWithExtraUUIDIsNotFound() {
    let path = "/i/" + edgeID + "?id=11111111-2222-3333-4444-555555555555"
    let d = LinkPolicy.decide(method: "GET", path: path, headers: ["Host": "127.0.0.1:47823"], port: 47823)
    #expect(d == .notFound)
    #expect(LinkPolicy.decide(method: "GET", path: "/i/" + edgeID + "?", headers: ["Host": "127.0.0.1:47823"], port: 47823)
            == .notFound)
    #expect(LinkPolicy.decide(method: "GET", path: "/health?x=1", headers: ["Host": "127.0.0.1:47823"], port: 47823)
            == .health)
}

@Test func copyTextTrimsTrailingCRLF() {
    #expect(Sanitize.copyText("ls\r\n") == "ls")
    #expect(Sanitize.copyText("ls \r") == "ls")
    #expect(Sanitize.copyText("a\rb\r\n") == "a⟨U+000D⟩b")
}
