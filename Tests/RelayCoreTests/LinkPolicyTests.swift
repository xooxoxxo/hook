import Foundation
import Testing
@testable import RelayCore

private let id = "6f1c2b0e-8a1d-4c55-9a77-0d2f3c4b5a61"
private let path = "/i/" + id

private func decide(_ headers: [String: String], method: String = "GET") -> LinkDecision {
    LinkPolicy.decide(method: method, path: path, headers: headers, port: 47823)
}

@Test func curlLikeRequestIsAllowed() {
    #expect(decide(["Host": "127.0.0.1:47823", "User-Agent": "curl/8.7.1"]) == .open(id: id))
    #expect(LinkPolicy.decide(method: "GET", path: "/health", headers: ["host": "localhost:47823"], port: 47823)
            == .health)
}

@Test func chatAppLinkRequestIsAllowed() {
    let headers = [
        "host": "127.0.0.1:47823", "sec-fetch-site": "none", "sec-fetch-mode": "navigate",
        "SEC-FETCH-DEST": "document", "Sec-Fetch-User": "?1",
    ]
    #expect(decide(headers) == .open(id: id))
}

@Test func imageRequestIsForbidden() {
    let headers = ["Host": "127.0.0.1:47823", "Sec-Fetch-Site": "cross-site", "Sec-Fetch-Dest": "image"]
    #expect(decide(headers) == .forbidden)
}

@Test func crossSiteNavigationIsForbidden() {
    let headers = [
        "Host": "127.0.0.1:47823", "Sec-Fetch-Site": "cross-site",
        "Sec-Fetch-Mode": "navigate", "Sec-Fetch-Dest": "document",
    ]
    #expect(decide(headers) == .forbidden)
}

@Test func badHostIsForbidden() {
    #expect(decide(["Host": "rebind.attacker.example:47823"]) == .forbidden)
    #expect(decide(["Host": "127.0.0.1:1234"]) == .forbidden)
    #expect(decide([:]) == .forbidden)
}

@Test func postIsNotFound() {
    #expect(decide(["Host": "127.0.0.1:47823"], method: "POST") == .notFound)
}

@Suite struct LinkPolicyTests {
    private func parse(_ text: String) -> RelayURLAction? {
        URL(string: text).flatMap(RelayURL.parse)
    }

    @Test func showOpensThePanel() {
        #expect(parse("relay://show") == .show)
        #expect(parse("RELAY://SHOW") == .show)
        #expect(parse("relay://show/") == .show)
    }

    @Test func anAskLinkCarriesTheNormalizedID() {
        #expect(parse("relay://i/" + id) == .open(id: id))
        #expect(parse("relay://i/" + id.uppercased()) == .open(id: id))
    }

    @Test func everythingElseIsRefused() {
        #expect(parse("relay://i/") == nil)
        #expect(parse("relay://i/not-a-uuid") == nil)
        #expect(parse("relay://i/\(id)/extra") == nil)
        #expect(parse("relay://show/extra") == nil)
        #expect(parse("relay://settings") == nil)
        #expect(parse("https://i/" + id) == nil)
        #expect(parse("relay:show") == nil)
    }
}
