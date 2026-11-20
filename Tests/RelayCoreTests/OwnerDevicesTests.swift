import CryptoKit
import Foundation
import os
import Testing
@testable import RelayCore

private let devicesPondKey = "mailbox:pond.example:8790#devices"
private let devicesPondURL = URL(string: "https://pond.example:8790")!
private let devicesSeal = SymmetricKey(data: Data(repeating: 7, count: 32))

/// A Pond for the revoke request: scripted request answer and poll statuses.
private actor RevokePond: QueueSource {
    var owner = OwnerStatus(required: false, keys: [
        OwnerKeyRow(id: "old", label: "studio-mac", status: "approved", created: "2026-11-04T10:00:00+00:00"),
        OwnerKeyRow(id: "phone", label: "Android phone", status: "approved", created: "2026-11-01T10:00:00+00:00"),
    ], maxKeys: 2)
    var requestResult: Result<RevokeRequest, QueueError> =
        .success(RevokeRequest(id: "r1", code: "482913", status: "pending", expires: "2026-11-20T10:10:00+00:00"))
    var polls: [Result<String, QueueError>] = [.success("pending"), .success("approved")]
    private(set) var calls: [String] = []

    func set(request: Result<RevokeRequest, QueueError>) { requestResult = request }
    func set(polls: [Result<String, QueueError>]) { self.polls = polls }

    func list() async throws -> [WireItem] { [] }
    func get(_ id: String) async throws -> AskDetail { throw QueueError.notSupported }
    func post(project: String, instructable: Data) async throws -> PostResult { throw QueueError.notSupported }
    func resolve(_ id: String, verdict: Verdict, note: String?) async throws -> WireItem { throw QueueError.notSupported }
    func reply(_ id: String, text: String) async throws -> WireItem { throw QueueError.notSupported }
    func answer(_ id: String, answers: [JSONValue]) async throws -> WireItem { throw QueueError.notSupported }
    func reopen(_ id: String) async throws -> WireItem { throw QueueError.notSupported }
    func recentlyClosed(within interval: TimeInterval) async throws -> [WireItem] { [] }
    func changes() async -> AsyncStream<Void>? { nil }

    func ownerStatus() async throws -> OwnerStatus {
        calls.append("owner")
        return owner
    }

    func requestRevoke(_ id: String) async throws -> RevokeRequest {
        calls.append("request " + id)
        return try requestResult.get()
    }

    func revokeRequest(_ id: String) async throws -> RevokeRequest {
        calls.append("poll " + id)
        let next = polls.count > 1 ? polls.removeFirst() : polls[0]
        let status = try next.get()
        if status == "approved" { owner.keys.removeAll { $0.id == "old" } }
        return RevokeRequest(id: id, status: status)
    }
}

/// A flow on a Mac without a working key (nothing in the Keychain), with the devices read.
@MainActor private func keylessFlow(_ pond: RevokePond) async -> OwnerKeyFlow {
    let flow = OwnerKeyFlow(secrets: MemorySecretStore(), seal: { devicesSeal }, label: "Studio",
                            sleep: { _ in await Task.yield() })
    await flow.attach(sourceKey: devicesPondKey, url: devicesPondURL, source: pond)?.value
    await flow.refresh()?.value
    return flow
}

private func response(_ request: URLRequest, _ status: Int, _ body: String) -> (Data, URLResponse) {
    (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
}

/// A client whose token comes from memory and whose requests go to `handler`.
private func devicesClient(ownerKey: (@Sendable () async -> String?)? = nil,
                           _ handler: @escaping @Sendable (URLRequest) -> (Int, String))
    -> (MailboxClient, OSAllocatedUnfairLock<[URLRequest]>) {
    let name = SecretName.pondToken(sourceKey: "synthetic-devices")
    let tokens = MemorySecretStore([name: Data("synthetic-token".utf8)])
    let sent = OSAllocatedUnfairLock(initialState: [URLRequest]())
    let client = MailboxClient(settings: MailboxSettings(url: devicesPondURL, tokenFile: "unused", context: "test"),
                               tokenSource: KeychainTokenSource(store: tokens, name: name), ownerKey: ownerKey,
                               keychain: KeychainQueue(label: "test.devices"), transport: { request in
        sent.withLock { $0.append(request) }
        let (status, body) = handler(request)
        return response(request, status, body)
    })
    return (client, sent)
}

@Suite struct OwnerDevicesDecodingTests {
    @Test func ownerStatusDecodesDatesAndLimit() throws {
        let json = #"""
        {"required":false,"maxKeys":10,"self":{"id":"k1","status":"approved"},
         "keys":[{"id":"k1","label":"studio-mac","status":"approved","created":"2026-11-14T09:00:00+00:00",
                  "approvedAt":"2026-11-14T09:01:00+00:00","lastUsed":"2026-11-20T08:00:00+00:00"},
                 {"id":"k2","label":"Android phone","status":"approved","created":"2026-11-02T18:30:00+00:00",
                  "approvedAt":null,"lastUsed":null}]}
        """#
        let status = try JSONDecoder().decode(OwnerStatus.self, from: Data(json.utf8))
        #expect(status.maxKeys == 10)
        #expect(status.keys[0].lastUsed == "2026-11-20T08:00:00+00:00")
        #expect(status.keys[1].lastUsed == nil)
        #expect(status.self_ == OwnerSelf(id: "k1", status: "approved"))
    }

    @Test func olderPondDecodesWithoutDatesOrLimit() throws {
        let json = #"{"required":false,"keys":[{"id":"k1","label":"m","status":"approved","created":""}],"self":null}"#
        let status = try JSONDecoder().decode(OwnerStatus.self, from: Data(json.utf8))
        #expect(status.maxKeys == nil && status.keys[0].lastUsed == nil && status.self_ == nil)
    }

    @Test func malformedNewFieldsNeverHideTheDevices() throws {
        let json = #"{"required":true,"maxKeys":"ten","keys":[{"id":"k1","label":"m","status":"approved","created":"x","lastUsed":5}]}"#
        let status = try JSONDecoder().decode(OwnerStatus.self, from: Data(json.utf8))
        #expect(status.maxKeys == nil && status.keys.count == 1 && status.keys[0].lastUsed == nil)
        let zero = try JSONDecoder().decode(OwnerStatus.self, from: Data(#"{"required":false,"keys":[],"maxKeys":0}"#.utf8))
        #expect(zero.maxKeys == nil)
    }

    @Test func revokeRequestDecodes() throws {
        let created = try JSONDecoder().decode(RevokeRequest.self, from: Data(
            #"{"id":"r1","code":"048213","expires":"2026-11-20T10:10:00+00:00","status":"pending"}"#.utf8))
        #expect(created == RevokeRequest(id: "r1", code: "048213", status: "pending", expires: "2026-11-20T10:10:00+00:00"))
        let polled = try JSONDecoder().decode(RevokeRequest.self, from: Data(#"{"id":"r1","status":"approved"}"#.utf8))
        #expect(polled.status == "approved" && polled.code == nil)
    }

    @Test func featuresAreReadFromTheListOnly() {
        let v110 = PondVersion.semver(SemVer(major: 1, minor: 10, patch: 0))
        let listed = PondCapabilities(version: v110, features: ["ownerRevokeRequest", "ownerKeyDates"])
        #expect(listed.supports(.ownerRevokeRequest) && listed.supports(.ownerKeyDates))
        #expect(!PondCapabilities(version: v110, features: nil).supports(.ownerRevokeRequest))
        #expect(!PondCapabilities(version: v110, features: ["appendSteps"]).supports(.ownerKeyDates))
        // Never in the "older Pond" Notice: Hook works without them.
        #expect(MailboxProtocol.missingFeatures(pond: .semver(SemVer(major: 1, minor: 1, patch: 0))).isEmpty)
    }
}

@Suite struct OwnerDevicesClientTests {
    @Test func revokeRequestGoesWithTheTokenAloneAndPollsByID() async throws {
        let (client, sent) = devicesClient(ownerKey: { "synthetic-approved-owner-key" }) { request in
            request.httpMethod == "POST"
                ? (201, #"{"id":"r1","code":"482913","expires":"2026-11-20T10:10:00+00:00","status":"pending"}"#)
                : (200, #"{"id":"r1","status":"rejected"}"#)
        }
        let request = try await client.requestRevoke("old")
        #expect(request.code == "482913" && request.status == "pending")
        #expect(try await client.revokeRequest("r1").status == "rejected")
        let requests = sent.withLock { $0 }
        #expect(requests.map { $0.httpMethod! + " " + $0.url!.path() } ==
                ["POST /owner/revoke-request", "GET /owner/revoke-request/r1"])
        #expect(try JSONValue.parse(requests[0].httpBody!) == .object(["id": .string("old")]))
        // The Pond token alone: never this Mac's owner key.
        #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: MailboxClient.ownerKeyHeader) == nil })
        #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-token" })
    }

    @Test(arguments: [
        (409, #"{"error":"revoke request pending"}"#, OwnerDevices.revokeAlreadyPending, false),
        (409, #"{"error":"already revoked"}"#, OwnerDevices.revokeAlreadyRevoked, true),
        (409, #"{"error":"not approved"}"#, OwnerDevices.revokeNotApproved, false),
        (404, #"{"error":"not found"}"#, OwnerDevices.revokeGone, true),
        (502, #"{"error":"telegram send failed"}"#, OwnerDevices.revokeTelegramFailed, false),
        (429, #"{"error":"rate limited"}"#, OwnerDevices.revokeRateLimited, false),
    ])
    func refusalsBecomePlainWords(status: Int, body: String, text: String, gone: Bool) async throws {
        let (client, _) = devicesClient { _ in (status, body) }
        do {
            _ = try await client.requestRevoke("old")
            Issue.record("expected a refusal")
        } catch {
            let refused = OwnerDevices.requestRefused(error)
            #expect(refused.reason == text)
            #expect(refused.gone == gone)
        }
    }
}

@Suite struct OwnerDevicesLogicTests {
    let v110 = PondVersion.semver(SemVer(major: 1, minor: 10, patch: 0))

    @Test func revokeGoesWithTheKeyThenTelegramThenNowhere() {
        let mine = OwnerStatus(required: false, keys: [], self_: OwnerSelf(id: "k", status: "approved"))
        let newPond = PondCapabilities(version: v110, features: ["ownerRevokeRequest"])
        let oldPond = PondCapabilities(version: .semver(SemVer(major: 1, minor: 9, patch: 0)), features: ["appendSteps"])
        #expect(OwnerDevices.revokePath(state: .approved, status: mine, capabilities: oldPond) == .ownerKey)
        #expect(OwnerDevices.revokePath(state: .approved, status: mine, capabilities: newPond) == .ownerKey)
        // A key the Pond no longer lists as approved is no working key.
        let revoked = OwnerStatus(required: false, keys: [], self_: OwnerSelf(id: "k", status: "revoked"))
        #expect(OwnerDevices.revokePath(state: .approved, status: revoked, capabilities: newPond) == .telegram)
        #expect(OwnerDevices.revokePath(state: .refused("x"), status: nil, capabilities: newPond) == .telegram)
        // An older Pond: only the Mac-key path.
        #expect(OwnerDevices.revokePath(state: .refused("x"), status: nil, capabilities: oldPond) == .unavailable)
        #expect(OwnerDevices.revokePath(state: .notSetUp, status: nil, capabilities: nil) == .unavailable)
    }

    @Test func olderPondShowsNamesOnly() {
        let status = OwnerStatus(required: false, keys: [
            OwnerKeyRow(id: "a", label: "studio-mac", status: "approved", created: "2026-11-04T10:00:00+00:00"),
        ])
        #expect(!OwnerDevices.showsDates(PondCapabilities(version: v110, features: ["appendSteps"])))
        #expect(!OwnerDevices.showsDates(nil))
        let rows = OwnerDevices.rows(status, dates: false)
        #expect(rows.map(\.name) == ["studio-mac"])
        #expect(rows[0].setUp == nil && rows[0].lastUsed == nil)
        #expect(OwnerDevices.slots(status) == "1 device")
        #expect(!OwnerDevices.full(status))
    }

    @Test func thisMacFirstThenNewestWithDates() throws {
        let now = try #require(Timestamp.date("2026-11-20T12:00:00+00:00"))
        let status = OwnerStatus(required: false, keys: [
            OwnerKeyRow(id: "old", label: "studio-mac", status: "approved", created: "2026-11-04T10:00:00+00:00"),
            OwnerKeyRow(id: "phone", label: "Android phone", status: "approved", created: "2026-11-06T10:00:00+00:00",
                        lastUsed: "2026-11-19T21:00:00+00:00"),
            OwnerKeyRow(id: "mac", label: "studio-mac", status: "approved", created: "2026-11-01T10:00:00+00:00",
                        lastUsed: "2026-11-20T08:00:00+00:00"),
            OwnerKeyRow(id: "new", label: "Tablet", status: "pending", created: "2025-11-10T10:00:00+00:00"),
        ], self_: OwnerSelf(id: "mac", status: "approved"), maxKeys: 4)
        let rows = OwnerDevices.rows(status, dates: true, now: now, locale: Locale(identifier: "en_GB"),
                                     timeZone: TimeZone(identifier: "UTC")!)
        #expect(rows.map(\.id) == ["mac", "phone", "old", "new"])
        #expect(rows[0].isThisMac && !rows[1].isThisMac)
        #expect(rows.map(\.lastUsed) == ["Today", "Yesterday", "—", OwnerDevices.waiting])
        #expect(rows[2].setUp == "4 Nov")
        #expect(rows[3].setUp == "10 Nov 2025")
        #expect(OwnerDevices.slots(status) == "4 of 4 slots used")
        #expect(OwnerDevices.full(status))
    }

    @Test func onlySixDigitCodesAreShown() {
        #expect(OwnerDevices.validCode("048213") == "048213")
        #expect(OwnerDevices.validCode("48213") == nil)
        #expect(OwnerDevices.validCode("48a213") == nil)
        #expect(OwnerDevices.validCode(nil) == nil)
    }
}

@Suite @MainActor struct RevokeRequestFlowTests {
    @Test func approvedOnTelegramRefreshesTheDevices() async throws {
        let pond = RevokePond(), flow = await keylessFlow(pond)
        #expect(flow.status?.keys.count == 2)
        let task = try #require(flow.requestRevoke("old"))
        await task.value
        #expect(flow.revokeRequest == .revoked(keyID: "old"))
        #expect(flow.status?.keys.map(\.id) == ["phone"])
        #expect(await pond.calls == ["owner", "request old", "poll r1", "poll r1", "owner"])
    }

    @Test func waitingShowsTheCodeUntilTheTap() async throws {
        let pond = RevokePond()
        await pond.set(polls: [.success("pending")])
        let gate = AsyncStream<Void>.makeStream()
        let flow = OwnerKeyFlow(secrets: MemorySecretStore(), seal: { devicesSeal }, label: "Studio",
                                sleep: { _ in for await _ in gate.stream { return }; throw CancellationError() })
        await flow.attach(sourceKey: devicesPondKey, url: devicesPondURL, source: pond)?.value
        await flow.refresh()?.value
        let task = try #require(flow.requestRevoke("old"))
        while flow.revokeRequest == .sending(keyID: "old") { await Task.yield() }
        guard case .waiting(let key, let id, let code, let expires) = flow.revokeRequest else {
            Issue.record("expected waiting, got \(flow.revokeRequest)")
            return
        }
        #expect(key == "old" && id == "r1" && code == "482913" && expires != nil)
        // A second request waits for this one.
        #expect(flow.requestRevoke("phone") == nil)
        flow.cancelRevokeRequest()
        gate.continuation.finish()
        await task.value
        #expect(flow.revokeRequest == .idle)
    }

    @Test(arguments: [("rejected", OwnerDevices.revokeDeclined), ("expired", OwnerDevices.revokeExpired)])
    func turnedDownOrExpiredEndsWithItsReason(status: String, reason: String) async throws {
        let pond = RevokePond()
        await pond.set(polls: [.success("pending"), .success(status)])
        let flow = await keylessFlow(pond)
        await flow.requestRevoke("old")?.value
        #expect(flow.revokeRequest == .ended(keyID: "old", reason: reason))
        #expect(flow.status?.keys.count == 2)
    }

    @Test func aFailedPollIsRetriedAndAGoneRequestExpires() async throws {
        let pond = RevokePond()
        await pond.set(polls: [.failure(.unreachable("offline")), .success("approved")])
        let flow = await keylessFlow(pond)
        await flow.requestRevoke("old")?.value
        #expect(flow.revokeRequest == .revoked(keyID: "old"))

        let gone = RevokePond()
        await gone.set(polls: [.failure(.notFound)])
        let other = await keylessFlow(gone)
        await other.requestRevoke("old")?.value
        #expect(other.revokeRequest == .ended(keyID: "old", reason: OwnerDevices.revokeExpired))
    }

    @Test func aPendingPollRunsOutAtTheLimit() async throws {
        let pond = RevokePond()
        await pond.set(polls: [.success("pending")])
        let flow = await keylessFlow(pond)
        await flow.requestRevoke("old")?.value
        #expect(flow.revokeRequest == .ended(keyID: "old", reason: OwnerDevices.revokeExpired))
        #expect(await pond.calls.filter { $0 == "poll r1" }.count == Int(OwnerKeyFlow.pollLimit / OwnerKeyFlow.pollInterval))
    }

    @Test func aRefusedRequestSaysWhyAndAGoneDeviceRefreshes() async throws {
        let pond = RevokePond()
        await pond.set(request: .failure(.rejected(status: 409, error: "already revoked", details: [])))
        let flow = await keylessFlow(pond)
        await flow.requestRevoke("old")?.value
        #expect(flow.revokeRequest == .ended(keyID: "old", reason: OwnerDevices.revokeAlreadyRevoked))
        #expect(await pond.calls == ["owner", "request old", "owner"])

        let bad = RevokePond()
        await bad.set(request: .success(RevokeRequest(id: "r1", code: "12", status: "pending")))
        let other = await keylessFlow(bad)
        await other.requestRevoke("old")?.value
        guard case .ended = other.revokeRequest else { Issue.record("a bad code is never shown"); return }
    }

    @Test func anUnknownDeviceIsNeverAskedFor() async throws {
        let pond = RevokePond(), flow = await keylessFlow(pond)
        #expect(flow.requestRevoke("nobody") == nil)
        #expect(flow.revokeRequest == .idle)
    }

    @Test func anotherPondStopsTheRequest() async throws {
        let pond = RevokePond()
        await pond.set(polls: [.success("pending")])
        let flow = await keylessFlow(pond)
        let task = try #require(flow.requestRevoke("old"))
        flow.attach(sourceKey: "mailbox:other.example#x", url: devicesPondURL, source: RevokePond())
        await task.value
        #expect(flow.revokeRequest == .idle)
    }

    @Test func tooManyKeysIsRemembered() {
        #expect(OwnerKeyFlow.isFull(QueueError.rejected(status: 409, error: "too many keys", details: [])))
        #expect(!OwnerKeyFlow.isFull(QueueError.rejected(status: 409, error: "already enrolled", details: [])))
        #expect(!OwnerKeyFlow.isFull(QueueError.notFound))
    }
}
