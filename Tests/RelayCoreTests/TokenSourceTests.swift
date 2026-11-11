import CryptoKit
import Foundation
import Security
import Testing
@testable import RelayCore

@Suite struct TokenSourceTests {
    @Test func fileTokenTrimsWhitespaceAndRefusesEmptyOrMissingFiles() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "hook-token-\(UUID())")
        defer { try? FileManager.default.removeItem(at: file) }
        let source = FileTokenSource(path: file.path)
        try Data(" \n tok-example \t\n".utf8).write(to: file)
        #expect(try source.readToken() == "tok-example")
        #expect(!source.requiresHTTPS)
        try Data(" \n\t".utf8).write(to: file)
        #expect(throws: ConfigError.self) { try source.readToken() }
        try FileManager.default.removeItem(at: file)
        #expect(throws: ConfigError.self) { try source.readToken() }
    }

    @Test func keychainTokenRefusesMissingEmptyAndInvalidUTF8() throws {
        let name = SecretName.pondToken(sourceKey: "pond")
        let store = MemorySecretStore()
        let source = KeychainTokenSource(store: store, name: name)
        #expect(source.requiresHTTPS)
        for data in [nil, Data(), Data(" \n".utf8), Data([0xff])] {
            try store.delete(name)
            if let data { try store.write(name, data) }
            #expect(throws: TokenSourceError.unreadableToken) { try source.readToken() }
        }
        try store.write(name, Data(" token \n".utf8))
        #expect(try source.readToken() == "token")
        store.readError = .unreadable(errSecInteractionNotAllowed)
        #expect(throws: TokenSourceError.unreadableToken) { try source.readToken() }
    }

    @Test @MainActor func heldTokenReadLeavesMainActorFreeAndUsesKeychainQueue() async throws {
        let host = "token-held-" + UUID().uuidString.lowercased() + ".test"
        let name = SecretName.pondToken(sourceKey: host)
        let store = MemorySecretStore([name: Data("phone-token".utf8)])
        store.holdReads()
        defer { store.releaseReads() }
        let client = makeClient(host: host, source: KeychainTokenSource(store: store, name: name))
        let task = Task { try await client.list() }
        while store.waitingReads == 0 { await Task.yield() }
        #expect(MailboxStubRegistry.shared.last(host) == nil)
        store.releaseReads()
        #expect(try await task.value.isEmpty)
    }

    @Test func keychainTokenGoesOnlyToConfiguredHTTPSOriginAndKeepsProtocolSix() async throws {
        let host = "token-origin-" + UUID().uuidString.lowercased() + ".test"
        let name = SecretName.pondToken(sourceKey: host)
        let source = KeychainTokenSource(store: MemorySecretStore([name: Data("phone-token".utf8)]), name: name)
        _ = try await makeClient(host: host, source: source).list()
        let sent = try #require(MailboxStubRegistry.shared.last(host)?.request)
        #expect(sent.url?.scheme == "https")
        #expect(sent.url?.host == host)
        #expect(sent.url?.port == 9443)
        #expect(sent.url?.path == "/pond/asks")
        #expect(sent.value(forHTTPHeaderField: "Authorization") == "Bearer phone-token")
        #expect(sent.value(forHTTPHeaderField: MailboxClient.protocolHeader) == "6")
        for scheme in ["http", "ftp"] {
            let refusedHost = scheme + "-" + host
            await #expect(throws: QueueError.self) { try await makeClient(host: refusedHost, scheme: scheme, source: source).list() }
            #expect(MailboxStubRegistry.shared.last(refusedHost) == nil)
        }
    }

    @Test func explicitlyInjectedFileSourceRetainsLegacyHTTPCompatibility() async throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "hook-token-\(UUID())")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("file-token".utf8).write(to: file)
        let host = "file-http-" + UUID().uuidString.lowercased() + ".test"
        _ = try await makeClient(host: host, scheme: "http", source: FileTokenSource(path: file.path)).list()
        #expect(MailboxStubRegistry.shared.last(host)?.request.value(forHTTPHeaderField: "Authorization") == "Bearer file-token")
    }

    @Test func phoneTokenFailureNamesTokenWithoutAFileOrSecret() async throws {
        let client = makeClient(host: "missing-" + UUID().uuidString.lowercased() + ".test",
                                source: KeychainTokenSource(store: MemorySecretStore(), name: .pondToken(sourceKey: "pond")))
        do {
            _ = try await client.list()
            Issue.record("expected missing token failure")
        } catch QueueError.unreachable(let reason) {
            #expect(reason.lowercased().contains("token"))
            #expect(!reason.lowercased().contains("file"))
        }
    }

    @Test func rejectedPhoneTokenCopyDoesNotMentionAFile() async throws {
        let host = "token-rejected-" + UUID().uuidString.lowercased() + ".test"
        let name = SecretName.pondToken(sourceKey: host)
        let client = makeClient(host: host, source: KeychainTokenSource(store: MemorySecretStore([name: Data("token".utf8)]), name: name))
        MailboxStubRegistry.shared.register(host) { _, _ in (401, #"{"error":"unauthorized"}"#) }
        await #expect(throws: QueueError.tokenRejected) { try await client.list() }
        #expect(QueueError.tokenRejected.localizedDescription.contains("token"))
        #expect(!QueueError.tokenRejected.localizedDescription.contains("file"))
        #expect(MailboxClient.logged(.tokenRejected).status == 401)
    }

    @Test func keychainCredentialsAreReReadForEveryRequest() async throws {
        let host = "token-reread-" + UUID().uuidString.lowercased() + ".test"
        let name = SecretName.pondToken(sourceKey: host)
        let store = MemorySecretStore([name: Data("first".utf8)])
        let client = makeClient(host: host, source: KeychainTokenSource(store: store, name: name))
        _ = try await client.list()
        #expect(MailboxStubRegistry.shared.last(host)?.request.value(forHTTPHeaderField: "Authorization") == "Bearer first")
        try store.write(name, Data("second".utf8))
        _ = try await client.list()
        #expect(MailboxStubRegistry.shared.last(host)?.request.value(forHTTPHeaderField: "Authorization") == "Bearer second")
    }

    @Test func phoneProviderUsesMarkedEnrollmentAndPropagatesSealReadFailures() async throws {
        let host = "owner-approved-" + UUID().uuidString.lowercased() + ".test"
        let name = SecretName.pondToken(sourceKey: host)
        let ownerStore = MemorySecretStore()
        let seal = SymmetricKey(data: Data(repeating: 8, count: 32))
        try OwnerKeyVault.save(OwnerKeyRecord(key: "owner-key", status: .approved, scheme: "https"), ownerStore, sourceKey: host, seal: seal)
        let url = URL(string: "https://\(host):9443/pond")!
        let provider = OwnerKeyFlow.authenticatedProvider(ownerStore, sourceKey: host, url: url, seal: { seal })
        #expect(try await provider() == "owner-key")
        let client = makeClient(host: host, source: KeychainTokenSource(store: MemorySecretStore([name: Data("token".utf8)]), name: name), ownerKey: provider)
        MailboxStubRegistry.shared.register(host) { _, _ in (200, #"{"required":false,"keys":[],"self":null}"#) }
        _ = try await client.ownerStatus()
        #expect(MailboxStubRegistry.shared.last(host)?.request.value(forHTTPHeaderField: MailboxClient.ownerKeyHeader) == "owner-key")
        let lockedSeal = OwnerKeyFlow.authenticatedProvider(ownerStore, sourceKey: host, url: url,
                                                            seal: { throw SecretStoreError.unreadable(errSecInteractionNotAllowed) })
        await #expect(throws: SecretStoreError.unreadable(errSecInteractionNotAllowed)) { try await lockedSeal() }
        let wrongSeal = OwnerKeyFlow.authenticatedProvider(ownerStore, sourceKey: host, url: url,
                                                           seal: { SymmetricKey(data: Data(repeating: 9, count: 32)) })
        await #expect(throws: SecretStoreError.foreign) { try await wrongSeal() }
    }

    @Test func ownerKeyReadFailureBlocksSignedPhoneActionsBeforeTransport() async throws {
        let host = "owner-locked-" + UUID().uuidString.lowercased() + ".test"
        let name = SecretName.pondToken(sourceKey: host)
        let ownerStore = MemorySecretStore()
        ownerStore.readError = .unreadable(errSecInteractionNotAllowed)
        let url = URL(string: "https://\(host):9443/pond")!
        let provider = OwnerKeyFlow.authenticatedProvider(ownerStore, sourceKey: host, url: url,
                                                          seal: { SymmetricKey(data: Data(repeating: 7, count: 32)) })
        let client = makeClient(host: host,
                                source: KeychainTokenSource(store: MemorySecretStore([name: Data("token".utf8)]), name: name),
                                ownerKey: provider)
        await #expect(throws: QueueError.self) { try await client.resolve("ask", verdict: .done, note: nil) }
        #expect(MailboxStubRegistry.shared.last(host) == nil)
    }

    @Test(arguments: [Data("not json".utf8), Data(), Data(#"{"key":"incomplete"}"#.utf8), Data("[]".utf8)])
    func malformedOwnerKeyRecordsBlockSignedPhoneActionsAndRemainUntouched(bytes: Data) async throws {
        let host = "owner-corrupt-" + UUID().uuidString.lowercased() + ".test"
        let tokenName = SecretName.pondToken(sourceKey: host)
        let ownerName = SecretName.ownerKey(sourceKey: host)
        let ownerStore = MemorySecretStore([ownerName: bytes])
        let url = URL(string: "https://\(host):9443/pond")!
        let seal = SymmetricKey(data: Data(repeating: 7, count: 32))
        let provider = OwnerKeyFlow.authenticatedProvider(ownerStore, sourceKey: host, url: url, seal: { seal })
        await #expect(throws: SecretStoreError.unreadable(errSecDecode)) { try await provider() }
        let client = makeClient(host: host,
                                source: KeychainTokenSource(store: MemorySecretStore([tokenName: Data("token".utf8)]), name: tokenName),
                                ownerKey: provider)
        MailboxStubRegistry.shared.register(host) { _, _ in (200, #"{"item":{"id":"ask","status":"done"}}"#) }
        do {
            _ = try await client.resolve("ask", verdict: .done, note: nil)
            Issue.record("expected malformed owner key to block the action")
        } catch QueueError.unreachable(let reason) {
            #expect(reason.contains("owner key"))
            #expect(!reason.contains("not json") && !reason.contains("incomplete"))
        }
        #expect(MailboxStubRegistry.shared.last(host) == nil)
        #expect(ownerStore.peek(ownerName) == bytes)
        #expect(ownerStore.writes == 0)
        #expect(ownerStore.creates == 0)
        // The Mac's established lenient reader/provider still treats malformed data as absent.
        #expect(try OwnerKeyVault.record(ownerStore, sourceKey: host, seal: seal) == nil)
        #expect(await OwnerKeyFlow.provider(ownerStore, sourceKey: host, url: url, seal: { seal })() == nil)
    }

    @Test func phoneProviderPreservesGenuineAbsenceForEnrollment() async throws {
        let store = MemorySecretStore()
        let url = URL(string: "https://pond.example.test")!
        let provider = OwnerKeyFlow.authenticatedProvider(store, sourceKey: "pond", url: url,
                                                          seal: { SymmetricKey(data: Data(repeating: 7, count: 32)) })
        #expect(try await provider() == nil)
        #expect(store.writes == 0)
    }

    @Test func redirectDelegateNeverReturnsACredentialBearingRequest() async throws {
        let origin = URL(string: "https://pond.example.test")!
        let response = HTTPURLResponse(url: origin, statusCode: 302, httpVersion: nil,
                                       headerFields: ["Location": "https://other.example.test"])!
        for target in ["https://other.example.test", "http://pond.example.test", "https://pond.example.test/elsewhere"] {
            var request = URLRequest(url: URL(string: target)!)
            request.setValue("Bearer phone-token", forHTTPHeaderField: "Authorization")
            request.setValue("owner-key", forHTTPHeaderField: MailboxClient.ownerKeyHeader)
            let redirected = await NoRedirectDelegate.shared.urlSession(.shared, task: URLSession.shared.dataTask(with: origin),
                                                                          willPerformHTTPRedirection: response, newRequest: request)
            #expect(redirected == nil)
        }
    }

    private func makeClient(host: String, scheme: String = "https", source: any TokenSource,
                            ownerKey: (@Sendable () async throws -> String?)? = nil) -> MailboxClient {
        MailboxStubRegistry.shared.register(host) { _, _ in (200, #"{"items":[]}"#) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MailboxStubProtocol.self]
        return MailboxClient(settings: MailboxSettings(url: URL(string: "\(scheme)://\(host):9443/pond")!, tokenFile: "", context: "work"),
                             session: URLSession(configuration: configuration), tokenSource: source,
                             ownerKey: ownerKey, keychain: KeychainQueue(label: "test.token.\(host)"))
    }
}
