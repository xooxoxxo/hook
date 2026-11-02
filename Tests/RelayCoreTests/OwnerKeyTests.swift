import CryptoKit
import Foundation
import Testing
@testable import RelayCore

/// Fixtures/revision-vectors.json: the Pond's shared vectors (gen_revision_vectors).
private func revisionCases(_ kind: String) throws -> [JSONValue] {
    let url = try #require(Bundle.module.url(
        forResource: "revision-vectors", withExtension: "json", subdirectory: "Fixtures"))
    let root = try JSONValue.parse(Data(contentsOf: url))
    guard root["version"] == .int(1), case .array(let cases)? = root["cases"] else {
        Issue.record("revision-vectors.json has no version 1 cases")
        return []
    }
    #expect(cases.count >= 60)
    return cases.filter { $0["kind"]?.stringValue == kind }
}

private let sourceKey = "mailbox:pond.example:8790#personal"

private let seal = SymmetricKey(data: Data(repeating: 9, count: 32))
private let pondURL = URL(string: "https://pond.example:8790")!

private func store(with record: OwnerKeyRecord?) throws -> MemorySecretStore {
    let store = MemorySecretStore()
    if let record { try OwnerKeyVault.save(record, store, sourceKey: sourceKey, seal: seal) }
    return store
}

@Suite struct OwnerKeyTests {
    @Test func aKeyIs43Base64urlCharacters() {
        var seen = Set<String>()
        for _ in 0..<20 {
            let key = OwnerKey.generate()
            #expect(key.count == 43)
            #expect(key.unicodeScalars.allSatisfy {
                ("A"..."Z").contains($0) || ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" || $0 == "_"
            })
            seen.insert(key)
        }
        #expect(seen.count == 20)
    }

    @Test func theHashMatchesTheKeyHashVectors() throws {
        let cases = try revisionCases("keyHash")
        #expect(!cases.isEmpty)
        for item in cases {
            let secret = try #require(item["secret"]?.stringValue)
            #expect(OwnerKey.hash(secret) == item["hash"]?.stringValue, "\(secret)")
        }
    }

    @Test func theCodeMatchesTheEnrollCodeVectors() throws {
        let cases = try revisionCases("enrollCode")
        #expect(!cases.isEmpty)
        for item in cases {
            let id = try #require(item["id"]?.stringValue), keyHash = try #require(item["keyHash"]?.stringValue)
            let code = OwnerKey.enrollCode(id: id, keyHash: keyHash)
            #expect(code == item["code"]?.stringValue, "\(id)")
            #expect(code.count == 6)
        }
    }

    @Test func onlyAnApprovedRecordGivesItsKey() throws {
        let key = OwnerKey.generate()
        #expect(OwnerKeyVault.approvedKey(try store(with: nil), sourceKey: sourceKey, url: pondURL, seal: seal) == nil)
        for status in [OwnerKeyRecord.Status.pending, .refused] {
            let pending = try store(with: OwnerKeyRecord(key: key, enrollID: "e1", status: status, scheme: "https"))
            #expect(OwnerKeyVault.approvedKey(pending, sourceKey: sourceKey, url: pondURL, seal: seal) == nil, "\(status)")
        }
        let approved = try store(with: OwnerKeyRecord(key: key, enrollID: "e1", status: .approved, scheme: "https"))
        #expect(OwnerKeyVault.approvedKey(approved, sourceKey: sourceKey, url: pondURL, seal: seal) == key)
        #expect(OwnerKeyVault.approvedKey(approved, sourceKey: "mailbox:other.example#personal", url: pondURL, seal: seal) == nil)
        approved.readError = .unreadable(-128)
        #expect(OwnerKeyVault.approvedKey(approved, sourceKey: sourceKey, url: pondURL, seal: seal) == nil)
        let garbage = MemorySecretStore([.ownerKey(sourceKey: sourceKey): Data("not json".utf8)])
        #expect(OwnerKeyVault.approvedKey(garbage, sourceKey: sourceKey, url: pondURL, seal: seal) == nil)
    }

    /// Hook marks each record it writes with an HMAC under its review seal: one another process
    /// planted (whatever its access list says) has no such mark and is refused, never sent.
    @Test func aRecordWithoutHooksMarkIsRefused() throws {
        let key = OwnerKey.generate()
        let name = SecretName.ownerKey(sourceKey: sourceKey)
        let unmarked = try JSONEncoder().encode(OwnerKeyRecord(key: key, enrollID: "e1", status: .approved, scheme: "https"))
        let planted = MemorySecretStore([name: unmarked])
        #expect(OwnerKeyVault.approvedKey(planted, sourceKey: sourceKey, url: pondURL, seal: seal) == nil)
        #expect(throws: SecretStoreError.foreign) { try OwnerKeyVault.record(planted, sourceKey: sourceKey, seal: seal) }

        var forged = OwnerKeyRecord(key: key, enrollID: "e1", status: .approved, scheme: "https")
        forged.mark = OwnerKeyVault.mark(key: key, sourceKey: sourceKey, seal: SymmetricKey(size: .bits256))
        let wrongSeal = MemorySecretStore([name: try JSONEncoder().encode(forged)])
        #expect(OwnerKeyVault.approvedKey(wrongSeal, sourceKey: sourceKey, url: pondURL, seal: seal) == nil)

        // Hook's own record, copied to another Pond's item, doesn't verify there.
        let approved = try store(with: OwnerKeyRecord(key: key, enrollID: "e1", status: .approved, scheme: "https"))
        let other = "mailbox:other.example#personal"
        let copied = MemorySecretStore([.ownerKey(sourceKey: other): try #require(approved.peek(name))])
        #expect(OwnerKeyVault.approvedKey(copied, sourceKey: other, url: pondURL, seal: seal) == nil)
        // With no seal to check the mark against, nothing is trusted.
        #expect(OwnerKeyVault.approvedKey(approved, sourceKey: sourceKey, url: pondURL, seal: nil) == nil)
        #expect(throws: SecretStoreError.foreign) { try OwnerKeyVault.record(approved, sourceKey: sourceKey, seal: nil) }
    }

    @Test func onlyHTTPSOrThisMacMayCarryTheKey() throws {
        for url in ["https://pond.example", "HTTPS://pond.example:8790/x", "http://127.0.0.1:8790", "http://localhost:8790",
                    "http://[::1]:8790"] {
            #expect(OwnerKey.mayCarry(try #require(URL(string: url))), "\(url)")
        }
        for url in ["http://pond.example", "http://100.64.0.1:8790", "http://127.0.0.1.example.com", "ftp://pond.example"] {
            #expect(!OwnerKey.mayCarry(try #require(URL(string: url))), "\(url)")
        }
    }

    /// The key goes only to the scheme it was set up on, and never over plain http to another host.
    @Test func theKeyIsBoundToTheSchemeItWasSetUpOn() throws {
        let key = OwnerKey.generate()
        let https = try #require(URL(string: "https://pond.example:8790"))
        let http = try #require(URL(string: "http://pond.example:8790"))
        let approved = try store(with: OwnerKeyRecord(key: key, enrollID: "e1", status: .approved, scheme: "https"))
        #expect(OwnerKeyVault.approvedKey(approved, sourceKey: sourceKey, url: https, seal: seal) == key)
        #expect(OwnerKeyVault.approvedKey(approved, sourceKey: sourceKey, url: http, seal: seal) == nil)

        let local = try #require(URL(string: "http://127.0.0.1:8790"))
        let onLoopback = try store(with: OwnerKeyRecord(key: key, enrollID: "e1", status: .approved, scheme: "http"))
        #expect(OwnerKeyVault.approvedKey(onLoopback, sourceKey: sourceKey, url: local, seal: seal) == key)
        #expect(OwnerKeyVault.approvedKey(onLoopback, sourceKey: sourceKey,
                                          url: try #require(URL(string: "https://127.0.0.1:8790")), seal: seal) == nil)
        // A record that names no scheme names none the key may go to.
        let unbound = try store(with: OwnerKeyRecord(key: key, enrollID: "e1", status: .approved))
        #expect(OwnerKeyVault.approvedKey(unbound, sourceKey: sourceKey, url: https, seal: seal) == nil)
    }

    @Test func theRecordIsOneJSONItem() throws {
        let store = try store(with: OwnerKeyRecord(key: "k", enrollID: nil, status: .pending))
        let data = try #require(store.peek(.ownerKey(sourceKey: sourceKey)))
        let mark = OwnerKeyVault.mark(key: "k", sourceKey: sourceKey, seal: seal)
        #expect(mark.count == 64)
        #expect(String(decoding: data, as: UTF8.self) == #"{"key":"k","mark":""# + mark + #"","status":"pending","v":1}"#)
    }

    @Test func aLabelIsOneShortLine() {
        #expect(OwnerKeyFlow.label(from: "Studio") == "Studio")
        #expect(OwnerKeyFlow.label(from: "  a\u{202E}b\nc  ") == "abc")
        #expect(OwnerKeyFlow.label(from: String(repeating: "x", count: 60)).count == 40)
        #expect(OwnerKeyFlow.label(from: "\u{200B} ") == "Mac")
    }
}
