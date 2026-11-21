import Foundation
import os
import Testing
@testable import RelayCore

private let askID = "0b7d6f2e-5c1a-4e8b-9d3f-2a6c8e1f4b70"
private let tokenValue = "synthetic-pond-token-7c1e"
private let ownerKeyValue = "synthetic-owner-key-91af"
private let pondURL = URL(string: "https://pond.example.test")!

private func item(status: String = "open") -> String {
    #"{"id":"\#(askID)","source":"mailbox","title":"Rotate the key","status":"\#(status)","projectId":"Acme","#
        + #""lane":"work","created":"2026-11-20T09:30:00+00:00","updated":"2026-11-20T09:30:00+00:00","payload":{}}"#
}

private func event(_ seq: Int, kind: String, text: String, at: String = "2026-11-20T09:31:00+00:00") -> String {
    #"{"seq":\#(seq),"itemId":"\#(askID)","kind":"\#(kind)","actor":"owner","text":"\#(text)","at":"\#(at)"}"#
}

private func detail(_ events: [String], status: String = "open") -> String {
    #"{"item":\#(item(status: status)),"events":[\#(events.joined(separator: ","))]}"#
}

/// What the fake Pond saw and what it answers next, per request.
private final class FakePond: @unchecked Sendable {
    typealias Answer = (URLRequest) throws -> (Int, String)
    private let lock = NSLock()
    private var answers: [Answer]
    private(set) var requests: [URLRequest] = []
    private(set) var waiting: [Bool] = []
    private(set) var slept: [Duration] = []

    init(_ answers: [Answer]) { self.answers = answers }

    func next(_ request: URLRequest) throws -> (Data, URLResponse) {
        lock.lock()
        requests.append(request)
        let answer = answers.isEmpty ? { _ in (500, #"{"error":"no more answers"}"#) } : answers.removeFirst()
        lock.unlock()
        let (status, body) = try answer(request)
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }

    func noteWaiting(_ value: Bool) { lock.lock(); waiting.append(value); lock.unlock() }
    func noteSleep(_ value: Duration) { lock.lock(); slept.append(value); lock.unlock() }

    var posts: [URLRequest] { lock.lock(); defer { lock.unlock() }; return requests.filter { $0.httpMethod == "POST" } }
    var all: [URLRequest] { lock.lock(); defer { lock.unlock() }; return requests }
}

private func client(_ pond: FakePond, retry: Bool = true) -> MailboxClient {
    let name = SecretName.pondToken(sourceKey: "synthetic-delivery-\(UUID().uuidString)")
    let tokens = MemorySecretStore([name: Data(tokenValue.utf8)])
    let settings = MailboxSettings(url: pondURL, tokenFile: "unused", context: "test")
    let policy = PondRetryPolicy(sleep: { pond.noteSleep($0) }, onWaiting: { _, waiting in pond.noteWaiting(waiting) })
    return MailboxClient(settings: settings, tokenSource: KeychainTokenSource(store: tokens, name: name),
                         ownerKey: { ownerKeyValue }, keychain: KeychainQueue(label: "test.delivery.\(UUID().uuidString)"),
                         transport: { try pond.next($0) }, retry: retry ? policy : nil)
}

private func fail(_ code: URLError.Code) -> FakePond.Answer { { _ in throw URLError(code) } }
private func ok(_ body: String) -> FakePond.Answer { { _ in (200, body) } }

@Suite struct PondDeliveryTests {
    @Test func aSendThatNeverLeftTheMacIsRetriedUntilItGoes() async throws {
        let pond = FakePond([fail(.cannotConnectToHost), fail(.dnsLookupFailed), ok(#"{"item":\#(item())}"#)])
        let sent = try await client(pond).message(askID, text: "Use the staging key")
        #expect(sent.id == askID)
        #expect(pond.posts.count == 3)
        #expect(pond.all.allSatisfy { $0.httpMethod == "POST" })   // nothing to check: it was never sent
        #expect(pond.slept == [.seconds(2), .seconds(5)])
        #expect(pond.waiting == [true, false])
    }

    @Test func retriesStopAtTheLimitWithTheError() async throws {
        let pond = FakePond(Array(repeating: fail(.notConnectedToInternet), count: 6))
        await #expect(throws: QueueError.self) { try await client(pond).reply(askID, text: "yes") }
        #expect(pond.posts.count == 1 + PondRetryPolicy.standardDelays.count)
        #expect(pond.waiting == [true, false])
    }

    @Test func aRefusalIsNeverRetried() async throws {
        for status in [400, 403, 409, 422] {
            let pond = FakePond([{ _ in (status, #"{"error":"invalid message"}"#) }, ok(#"{"item":\#(item())}"#)])
            await #expect(throws: (any Error).self) { try await client(pond).message(askID, text: "hello") }
            #expect(pond.posts.count == 1, "status \(status)")
            #expect(pond.waiting.isEmpty)
            #expect(pond.slept.isEmpty)
        }
    }

    @Test func withoutAPolicyAWriteGoesOnce() async throws {
        let pond = FakePond([fail(.cannotConnectToHost), ok(#"{"item":\#(item())}"#)])
        await #expect(throws: QueueError.self) { try await client(pond, retry: false).message(askID, text: "hello") }
        #expect(pond.posts.count == 1)
    }

    @Test func aTimedOutMessageTheAskAlreadyHasIsNotSentAgain() async throws {
        let pond = FakePond([
            ok(detail([event(3, kind: "reply", text: "earlier")])),           // the ask as shown
            fail(.timedOut),                                                   // maybe sent
            ok(detail([event(3, kind: "reply", text: "earlier"), event(4, kind: "message", text: "Use the staging key")])),
        ])
        let client = client(pond)
        _ = try await client.get(askID)
        let sent = try await client.message(askID, text: "Use the staging key")
        #expect(sent.id == askID)
        #expect(pond.posts.count == 1)
        #expect(pond.all.map { $0.httpMethod ?? "" } == ["GET", "POST", "GET"])
        #expect(pond.waiting == [true, false])
    }

    @Test func aTimedOutReplyTheAskLacksIsSentOnceMore() async throws {
        let pond = FakePond([
            ok(detail([event(3, kind: "reply", text: "yes")])),
            fail(.timedOut),
            ok(detail([event(3, kind: "reply", text: "yes")])),                // the same words, but from before
            ok(#"{"item":\#(item())}"#),
        ])
        let client = client(pond)
        _ = try await client.get(askID)
        _ = try await client.reply(askID, text: " yes ")
        #expect(pond.all.map { $0.httpMethod ?? "" } == ["GET", "POST", "GET", "POST"])
    }

    @Test func aGatewayErrorChecksBeforeResending() async throws {
        let pond = FakePond([
            { _ in (504, #"{"error":"gateway timeout"}"#) },
            ok(detail([event(9, kind: "message", text: "on its way", at: Timestamp.string(Date()))])),
        ])
        // No earlier read: an event from around the send's start counts as it.
        _ = try await client(pond).message(askID, text: "on its way")
        #expect(pond.all.map { $0.httpMethod ?? "" } == ["POST", "GET"])
    }

    @Test func aTimedOutDoneIsFoundClosed() async throws {
        let pond = FakePond([fail(.networkConnectionLost), ok(detail([], status: "done"))])
        let closed = try await client(pond).resolve(askID, verdict: .done, note: nil, stamp: nil)
        #expect(closed.status == "done")
        #expect(pond.posts.count == 1)
    }

    @Test func anIdempotentActIsResentAfterATimeout() async throws {
        let pond = FakePond([fail(.timedOut), ok(#"{"item":\#(item())}"#)])
        _ = try await client(pond).progress(askID, tick: ["s1"], untick: [], stamp: nil)
        #expect(pond.all.map { $0.httpMethod ?? "" } == ["POST", "POST"])
    }

    @Test func aWriteGets30SecondsAndAPoll10() async throws {
        let pond = FakePond([ok(#"{"items":[]}"#), ok(#"{"item":\#(item())}"#)])
        let client = client(pond)
        _ = try await client.list()
        _ = try await client.reply(askID, text: "yes")
        #expect(pond.all.map(\.timeoutInterval) == [10, 30])
        #expect(pond.all.allSatisfy { !$0.assumesHTTP3Capable })
        #expect(MailboxClient.timeout(for: "GET") == 10)
        #expect(MailboxClient.timeout(for: "POST") == 30)
        #expect(MailboxClient.defaultSession.configuration.timeoutIntervalForRequest == 10)
        #expect(MailboxClient.defaultWriteSession.configuration.timeoutIntervalForRequest == 30)
        #expect(MailboxClient.defaultWriteSession.configuration.timeoutIntervalForResource >= 30)
    }

    @Test func certaintyFollowsWhatTheRequestReached() {
        #expect(PondRetryPolicy.certainty(for: URLError(.cannotFindHost), timing: nil) == .notSent)
        #expect(PondRetryPolicy.certainty(for: URLError(.secureConnectionFailed), timing: nil) == .notSent)
        #expect(PondRetryPolicy.certainty(for: URLError(.timedOut), timing: nil) == .maybeSent)
        #expect(PondRetryPolicy.certainty(for: URLError(.timedOut), timing: PondTiming(requestSent: true)) == .maybeSent)
        // The metrics show the request was never written: a timeout while connecting.
        #expect(PondRetryPolicy.certainty(for: URLError(.timedOut), timing: PondTiming(transactions: 1)) == .notSent)
        #expect(PondRetryPolicy.certainty(for: URLError(.cancelled), timing: nil) == nil)
        #expect(PondRetryPolicy.certainty(for: URLError(.serverCertificateUntrusted), timing: nil) == nil)
        #expect(PondRetryPolicy.certainty(forStatus: 502) == .maybeSent)
        #expect(PondRetryPolicy.certainty(forStatus: 500) == nil)
        #expect(PondRetryPolicy.certainty(forStatus: 404) == nil)
    }

    @Test func aProblemReportIsMatchedByStepAndNote() throws {
        let text = #"{\"id\":\"s2\",\"step\":\"2\",\"note\":\"wrong path\"}"#
        let data = Data(detail([event(5, kind: "problem", text: text)]).utf8)
        let ask = try JSONDecoder().decode(AskDetail.self, from: data)
        #expect(WriteLanding.problem(stepID: "s2", note: "wrong path").landed(in: ask, after: 4, since: Date()))
        #expect(!WriteLanding.problem(stepID: "s2", note: "wrong path").landed(in: ask, after: 5, since: Date()))
        #expect(!WriteLanding.problem(stepID: "s3", note: "wrong path").landed(in: ask, after: 4, since: Date()))
    }
}

@Suite struct PondTimingLogTests {
    private let timing = PondTiming(total: 30.0123, transactions: 1, dns: 0.003, connect: 0.041, tls: 0.0884, ttfb: nil,
                                    networkProtocol: "h2", reused: false, family: .ipv4, requestSent: true)

    @Test func theTimingLineHasEveryFieldOnOneLine() {
        let line = HookLog.Event.timing(type: "Pond", method: "POST", route: "asks/\(askID)/reply", attempt: 1,
                                        timeout: 30, timing: timing).line(home: "/Users/me", user: "me")
        #expect(line == "timing type=Pond method=POST route=asks/{id}/reply attempt=1 timeout=30s total=30012ms dns=3ms "
            + "connect=41ms tls=88ms ttfb=- protocol=h2 reused=false addr=ipv4 sent=true tx=1")
    }

    @Test func aProtocolNameCantCarryAnythingElse() {
        #expect(PondTiming.protocolLabel("h3\nBearer x") == "h3bearerx")
        #expect(PondTiming.family("192.168.1.10") == .ipv4)
        #expect(PondTiming.family("fe80::1%en0") == .ipv6)
    }

    /// A timed-out write through a real URLSession: its error and timing lines name no token,
    /// owner key, host, ask id or text.
    @Test func aFailedRequestLogsItsTimingWithoutSecrets() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "hook-timing-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = RollingLog(directory: dir, now: { Date() })
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 0.2
        configuration.timeoutIntervalForResource = 0.5
        let session = URLSession(configuration: configuration)
        // A port nothing listens on, on the loopback: the connect fails fast.
        let name = SecretName.pondToken(sourceKey: "synthetic-timing-\(UUID().uuidString)")
        let tokens = MemorySecretStore([name: Data(tokenValue.utf8)])
        let settings = MailboxSettings(url: URL(string: "https://127.0.0.1:9")!, tokenFile: "unused", context: "test")
        let client = MailboxClient(settings: settings, session: session,
                                   tokenSource: KeychainTokenSource(store: tokens, name: name),
                                   ownerKey: { ownerKeyValue }, keychain: KeychainQueue(label: "test.timing"))
        try await HookLog.withLog(log) {
            await #expect(throws: QueueError.self) { try await client.message(askID, text: "the secret plan") }
        }
        let lines = log.tail(10)
        #expect(lines.contains { $0.contains("error type=Pond") && $0.contains("route=asks/{id}/reply") })
        let timingLine = try #require(lines.first { $0.contains(" timing type=Pond method=POST route=asks/{id}/reply") })
        #expect(timingLine.contains("timeout=30s"))
        for line in lines {
            for secret in [tokenValue, ownerKeyValue, askID, "127.0.0.1", "the secret plan", "Bearer", "https://"] {
                #expect(!line.contains(secret), "\(secret) in \(line)")
            }
        }
    }
}

@Suite struct LocalNetworkGateTests {
    @Test func aLocalPondThatKeepsTimingOutWhileOnlineIsSaidOnce() {
        var gate = LocalNetworkGate()
        #expect(gate.record(.failed(.timedOut), pondIsLocal: true, internetUp: true) == nil)
        #expect(gate.record(.failed(.notConnectedToInternet), pondIsLocal: true, internetUp: true) == nil)
        #expect(gate.record(.failed(.timedOut), pondIsLocal: true, internetUp: true) == .blocked)
        // Not again while nothing changed.
        #expect(gate.record(.failed(.timedOut), pondIsLocal: true, internetUp: true) == nil)
        #expect(gate.record(.failed(.timedOut), pondIsLocal: true, internetUp: true) == nil)
        // The Pond answers: taken back, and it can be said again later.
        #expect(gate.record(.answered, pondIsLocal: true, internetUp: true) == .cleared)
        #expect(gate.record(.answered, pondIsLocal: true, internetUp: true) == nil)
        for _ in 0..<2 { _ = gate.record(.failed(.timedOut), pondIsLocal: true, internetUp: true) }
        #expect(gate.record(.failed(.timedOut), pondIsLocal: true, internetUp: true) == .blocked)
    }

    @Test func aRemotePondOrAnOfflineMacIsNotLocalNetworkPrivacy() {
        var remote = LocalNetworkGate()
        var offline = LocalNetworkGate()
        for _ in 0..<5 {
            #expect(remote.record(.failed(.timedOut), pondIsLocal: false, internetUp: true) == nil)
            #expect(offline.record(.failed(.timedOut), pondIsLocal: true, internetUp: false) == nil)
        }
        var other = LocalNetworkGate()
        for _ in 0..<5 { #expect(other.record(.failed(.serverCertificateUntrusted), pondIsLocal: true, internetUp: true) == nil) }
    }

    @Test func localAddressesAreRecognised() {
        for host in ["192.168.1.14", "10.0.0.3", "172.20.1.1", "169.254.3.3", "fd12:3456::1", "[fe80::1%en0]", "pond.local",
                     "Pond.LOCAL."] {
            #expect(LocalAddress.isLocal(host: host, resolved: []), "\(host)")
        }
        for host in ["8.8.8.8", "172.32.0.1", "pond.example.com", "2001:db8::1"] {
            #expect(!LocalAddress.isLocal(host: host, resolved: []), "\(host)")
        }
        #expect(LocalAddress.isLocal(host: "pond.example.com", resolved: ["192.168.1.14"]))
        #expect(!LocalAddress.isLocal(host: "pond.example.com", resolved: ["192.168.1.14", "203.0.113.5"]))
    }

    @Test func theNoticeOpensLocalNetworkPrivacy() {
        let notice = PanelNotice.localNetworkBlocked
        #expect(notice.text == "Hook can't reach your Pond on the local network. "
            + "Allow Hook in System Settings › Privacy & Security › Local Network.")
        #expect(notice.actionTitle == "Open System Settings")
        #expect(PanelNotice.localNetworkSettingsURL.absoluteString
            == "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork")
        #expect(HookLog.Event.localNetwork(blocked: true, reason: "local Pond keeps failing while online")
            .line(home: "/Users/me", user: "me") == #"local-network blocked=true reason="local Pond keeps failing while online""#)
    }
}
