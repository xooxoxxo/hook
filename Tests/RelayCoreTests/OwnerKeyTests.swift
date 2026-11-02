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

private func store(with record: OwnerKeyRecord?) throws -> MemorySecretStore {
    let store = MemorySecretStore()
    if let record { try OwnerKeyVault.save(record, store, sourceKey: sourceKey) }
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
        #expect(OwnerKeyVault.approvedKey(try store(with: nil), sourceKey: sourceKey) == nil)
        for status in [OwnerKeyRecord.Status.pending, .refused] {
            let pending = try store(with: OwnerKeyRecord(key: key, enrollID: "e1", status: status))
            #expect(OwnerKeyVault.approvedKey(pending, sourceKey: sourceKey) == nil, "\(status)")
        }
        let approved = try store(with: OwnerKeyRecord(key: key, enrollID: "e1", status: .approved))
        #expect(OwnerKeyVault.approvedKey(approved, sourceKey: sourceKey) == key)
        #expect(OwnerKeyVault.approvedKey(approved, sourceKey: "mailbox:other.example#personal") == nil)
        approved.readError = .unreadable(-128)
        #expect(OwnerKeyVault.approvedKey(approved, sourceKey: sourceKey) == nil)
        let garbage = MemorySecretStore([.ownerKey(sourceKey: sourceKey): Data("not json".utf8)])
        #expect(OwnerKeyVault.approvedKey(garbage, sourceKey: sourceKey) == nil)
    }

    @Test func theRecordIsOneJSONItem() throws {
        let store = try store(with: OwnerKeyRecord(key: "k", enrollID: nil, status: .pending))
        let data = try #require(store.peek(.ownerKey(sourceKey: sourceKey)))
        #expect(String(decoding: data, as: UTF8.self) == #"{"key":"k","status":"pending","v":1}"#)
    }

    @Test func aLabelIsOneShortLine() {
        #expect(OwnerKeyFlow.label(from: "Studio") == "Studio")
        #expect(OwnerKeyFlow.label(from: "  a\u{202E}b\nc  ") == "abc")
        #expect(OwnerKeyFlow.label(from: String(repeating: "x", count: 60)).count == 40)
        #expect(OwnerKeyFlow.label(from: "\u{200B} ") == "Mac")
    }
}
