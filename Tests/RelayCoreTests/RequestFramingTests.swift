import Foundation
import Testing
@testable import RelayCore

private let badRequest = FramingDecision.reject(.error(400, "bad request"))
private let tooLarge = FramingDecision.reject(.error(413, "body too large"))

@Suite struct RequestFramingTests {
    @Test func transferEncodingIsRefused() {
        #expect(RequestFraming.decide(method: "POST", headers: ["transfer-encoding": "chunked"]) == badRequest)
        #expect(RequestFraming.decide(method: "GET", headers: ["Transfer-Encoding": "chunked"]) == badRequest)
    }

    @Test(arguments: ["abc", "-1", "10,20", "12345678", "", "1 0", "+5", "0x10"])
    func malformedContentLengthIsRefused(_ value: String) {
        #expect(RequestFraming.decide(method: "POST", headers: ["content-length": value]) == badRequest)
    }

    @Test func oversizeBodyIsRefused() {
        #expect(RequestFraming.decide(method: "POST", headers: ["content-length": "65537"]) == tooLarge)
        #expect(RequestFraming.decide(method: "POST", headers: ["content-length": "9999999"]) == tooLarge)
        #expect(RequestFraming.decide(method: "POST", headers: ["content-length": "65536"]) == .read(bodyLength: 65536))
    }

    @Test func bodyLengths() {
        #expect(RequestFraming.decide(method: "POST", headers: ["content-length": "42"]) == .read(bodyLength: 42))
        #expect(RequestFraming.decide(method: "POST", headers: ["content-length": "0"]) == .read(bodyLength: 0))
        #expect(RequestFraming.decide(method: "POST", headers: [:]) == .read(bodyLength: 0))
        // A GET body is never read.
        #expect(RequestFraming.decide(method: "GET", headers: [:]) == .read(bodyLength: 0))
        #expect(RequestFraming.decide(method: "GET", headers: ["content-length": "10"]) == .read(bodyLength: 0))
    }
}

@Suite struct HTTPHeadTests {
    @Test func parsesRequestLineQueryAndHeaders() throws {
        let raw = "GET /asks?status=all&days=7&q=a+b%2Fc&status=open HTTP/1.1\r\n"
            + "Host: 127.0.0.1:47823\r\nX-Thing: one\r\nx-thing:  two \r\nAuthorization: Bearer abc\r\n\r\n"
        let head = try #require(HTTPRequest.parseHead(Data(raw.utf8)))
        #expect(head.method == "GET")
        #expect(head.path == "/asks")
        #expect(head.query == ["status": "all", "days": "7", "q": "a b/c"])
        #expect(head.headers["host"] == "127.0.0.1:47823")
        #expect(head.headers["x-thing"] == "one,two")
        #expect(head.headers["authorization"] == "Bearer abc")
    }

    @Test func ignoresBytesAfterTheBlankLine() throws {
        let raw = "POST /asks HTTP/1.0\r\nContent-Length: 2\r\n\r\n{}"
        let head = try #require(HTTPRequest.parseHead(Data(raw.utf8)))
        #expect(head.method == "POST")
        #expect(head.query.isEmpty)
        #expect(head.headers == ["content-length": "2"])
    }

    @Test(arguments: [
        "",
        "GET /asks\r\n\r\n",
        "GET /asks HTTP/2\r\n\r\n",
        "get /asks HTTP/1.1\r\n\r\n",
        "GET asks HTTP/1.1\r\n\r\n",
        "GET /asks HTTP/1.1\r\nNoColonHere\r\n\r\n",
        "GET /asks HTTP/1.1\r\nHost: a\r\n folded\r\n\r\n",
        "GET /asks HTTP/1.1\r\nBad Name: x\r\n\r\n",
        "GET /asks?days=%zz HTTP/1.1\r\n\r\n",
    ])
    func malformedHeadsAreNil(_ raw: String) {
        #expect(HTTPRequest.parseHead(Data(raw.utf8)) == nil)
    }
}

@Suite struct HTTPResponseTests {
    @Test func jsonAndErrorBodies() throws {
        let ok = HTTPResponse.json(200, .object(["ok": .bool(true)]))
        #expect(ok.headers == ["Content-Type": "application/json", "Cache-Control": "no-store"])
        #expect(String(decoding: ok.body, as: UTF8.self) == #"{"ok":true}"#)

        let plain = HTTPResponse.error(404, "not found")
        #expect(try JSONValue.parse(plain.body) == .object(["error": .string("not found")]))
        let detailed = HTTPResponse.error(400, "invalid project", details: ["project: required"])
        #expect(try JSONValue.parse(detailed.body)
            == .object(["error": .string("invalid project"), "details": .array([.string("project: required")])]))
    }

    @Test func serializedFraming() {
        var response = HTTPResponse.error(404, "not found")
        response.headers["Connection"] = "keep-alive"   // never sent twice
        let text = String(decoding: response.serialized(), as: UTF8.self)
        let body = #"{"error":"not found"}"#
        #expect(text == "HTTP/1.1 404 Not Found\r\n"
            + "Cache-Control: no-store\r\n"
            + "Content-Type: application/json\r\n"
            + "Connection: close\r\n"
            + "Content-Length: \(body.utf8.count)\r\n\r\n"
            + body)
        #expect(String(decoding: HTTPResponse(status: 413).serialized(), as: UTF8.self)
            .hasPrefix("HTTP/1.1 413 Content Too Large\r\n"))
    }
}

@Suite struct ResponseSerializationTests {
    @Test func headerLineBreaksAreStripped() {
        let response = HTTPResponse(status: 200, headers: ["X-Test": "x\r\nX-Evil: 1", "X-A\r\nB": "v"])
        let text = String(decoding: response.serialized(), as: UTF8.self)
        let lines = text.components(separatedBy: "\r\n")
        #expect(!lines.contains { $0.hasPrefix("X-Evil") })
        #expect(lines.contains("X-Test: xX-Evil: 1"))
        #expect(lines.contains("X-AB: v"))
    }
}

@Suite struct HealthTests {
    private let token = String(repeating: "ab", count: 32)
    private let nonce = String(repeating: "0f", count: 16)

    private func body(_ response: HTTPResponse) throws -> JSONValue {
        #expect(response.status == 200)
        return try JSONValue.parse(response.body)
    }

    @Test func plainHealth() throws {
        let local = try body(Health.response(source: "local", port: 47823, nonce: nil, token: token))
        #expect(local == .object([
            "ok": .bool(true), "app": .string("relay"), "source": .string("local"), "presence": .string("home"),
        ]))
        let none = try body(Health.response(source: "none", port: 47823, nonce: nonce, token: nil))
        #expect(none == .object([
            "ok": .bool(true), "app": .string("relay"), "source": .string("none"), "presence": .string("home"),
        ]))
    }

    @Test func presenceIsReported() throws {
        let away = try body(Health.response(source: "mailbox", port: 47823, nonce: nil, token: nil, presence: .away))
        #expect(away["presence"] == .string("away"))
        #expect(away["source"] == .string("mailbox"))
        let home = try body(Health.response(source: "local", port: 47823, nonce: nil, token: nil, presence: .home))
        #expect(home["presence"] == .string("home"))
    }

    @Test func proofOnlyForLocalWithAValidNonceAndAToken() throws {
        let proved = try body(Health.response(source: "local", port: 47823, nonce: nonce, token: token))
        #expect(proved["proof"] == .string(LocalToken.proof(token: token, port: 47823, nonce: nonce)))
        #expect(proved["proof"] != .string(LocalToken.proof(token: token, port: 47900, nonce: nonce)))
        #expect(proved["source"] == .string("local"))

        #expect(try body(Health.response(source: "local", port: 47823, nonce: "xyz", token: token))["proof"] == nil)
        #expect(try body(Health.response(source: "local", port: 47823, nonce: nonce, token: nil))["proof"] == nil)
        let mailbox = try body(Health.response(source: "mailbox", port: 47823, nonce: nonce, token: token))
        #expect(mailbox["proof"] == nil)
        #expect(mailbox["source"] == .string("mailbox"))
    }
}
