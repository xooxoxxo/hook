import CryptoKit
import Foundation
import Testing
@testable import RelayCore

@Suite struct PhonePairingTests {
    private func data(url: String = "https://pond.example.test", token: String = "synthetic-token", v: Int = 1) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["v": v, "url": url, "token": token, "context": "test"])
    }
    @Test func factoryUsesTheDecoderValidationAndSizeLimit() throws {
        let pairing = try PhonePairing.make(url: URL(string: "https://POND.example.test:443/")!, token: "synthetic-token", context: "test")
        #expect(pairing.url.absoluteString == "https://pond.example.test")
        #expect(throws: PhonePairing.Failure.destination) {
            try PhonePairing.make(url: URL(string: "http://pond.example.test")!, token: "synthetic-token", context: "test")
        }
        #expect(throws: PhonePairing.Failure.tooLarge) {
            try PhonePairing.make(url: URL(string: "https://pond.example.test")!, token: String(repeating: "t", count: 16384), context: "test")
        }
    }
    @Test func versionOneAndStableCredentialFreeIdentity() throws {
        let first = try PhonePairing.decode(data())
        #expect(first.v == 1)
        #expect(first.url.host == "pond.example.test")
        #expect(first.sourceKey == (try PhonePairing.decode(data(token: "other-token"))).sourceKey)
        #expect(!first.sourceKey.contains(first.token))
    }
    @Test func refusesMalformedOversizedAndUnknownVersions() throws {
        for bytes in [Data(), Data("{}".utf8), Data("[]".utf8), Data(repeating: 32, count: 16385), try data(v: 2)] {
            #expect(throws: PhonePairing.Failure.self) { try PhonePairing.decode(bytes) }
        }
        let duplicate = Data(#"{"v":1,"v":1,"url":"https://pond.example.test","token":"t","context":"test"}"#.utf8)
        #expect(throws: PhonePairing.Failure.self) { try PhonePairing.decode(duplicate) }
    }
    @Test func refusesInsecureDestinationsAndCredentials() throws {
        for url in ["http://pond.example.test", "file:///tmp/a", "https://u@pond.example.test", "https://u:p@pond.example.test", "https://pond.example.test?x=1", "https://pond.example.test#x", "https://pond.example.test:0"] {
            #expect(throws: PhonePairing.Failure.self) { try PhonePairing.decode(data(url: url)) }
        }
        for token in ["", "  ", "token\nInjected: yes"] {
            #expect(throws: PhonePairing.Failure.self) { try PhonePairing.decode(data(token: token)) }
        }
    }
    @Test func signedPhoneWritesNeverDowngradeExistingOwnerRecords() async throws {
        let secrets = MemorySecretStore(), seal = SymmetricKey(size: .bits256)
        let url = URL(string: "https://pond.example.test")!, source = "phone-source"
        let write = OwnerKeyFlow.authenticatedProvider(secrets, sourceKey: source, url: url, seal: { seal })
        let status = OwnerKeyFlow.authenticatedStatusProvider(secrets, sourceKey: source, url: url, seal: { seal })
        #expect(try await write() == nil)
        for state in [OwnerKeyRecord.Status.pending, .refused] {
            try OwnerKeyVault.save(OwnerKeyRecord(key: "synthetic-key", status: state, scheme: "https"), secrets, sourceKey: source, seal: seal)
            await #expect(throws: SecretStoreError.self) { try await write() }
            #expect(try await status() == nil)
        }
        try OwnerKeyVault.save(OwnerKeyRecord(key: "synthetic-key", status: .approved, scheme: "https"), secrets, sourceKey: source, seal: seal)
        #expect(try await write() == "synthetic-key")
        #expect(try await status() == "synthetic-key")
        let copied = try #require(try secrets.read(.ownerKey(sourceKey: source)))
        try secrets.write(.ownerKey(sourceKey: "other"), copied)
        let other = OwnerKeyFlow.authenticatedProvider(secrets, sourceKey: "other", url: url, seal: { seal })
        await #expect(throws: SecretStoreError.self) { try await other() }
        try OwnerKeyVault.save(OwnerKeyRecord(key: "synthetic-key", status: .approved, scheme: "http"), secrets, sourceKey: source, seal: seal)
        await #expect(throws: SecretStoreError.self) { try await write() }
        await #expect(throws: SecretStoreError.self) { try await status() }
        try secrets.write(.ownerKey(sourceKey: source), Data("malformed".utf8))
        await #expect(throws: SecretStoreError.self) { try await write() }
    }

}
