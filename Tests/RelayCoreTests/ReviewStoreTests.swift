import CryptoKit
import Foundation
import Testing
@testable import RelayCore

private let source = "mailbox:pond.example:8790#personal"

private func tempFile() -> URL {
    FileManager.default.temporaryDirectory.appending(path: "relay-reviews-\(UUID().uuidString).json")
}

private func record(_ rev: Int = 2) -> ReviewRecord {
    ReviewRecord(accepted: RevisionStamp(rev: rev, hash: String(repeating: "a", count: 64)),
                 seen: RevisionStamp(rev: 1, hash: String(repeating: "b", count: 64)),
                 pins: [1: String(repeating: "b", count: 64), rev: String(repeating: "a", count: 64)],
                 changed: ["s3"], pondAcceptPending: true, added: ["s6"])
}

/// The raw file as an editable JSON object.
private func object(_ url: URL) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
}

@Suite struct ReviewStoreTests {
    @Test func aSealedFileRoundTrips() throws {
        let key = SymmetricKey(size: .bits256), url = tempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let records = [ReviewStore.key(sourceKey: source, id: "a"): record(), ReviewStore.key(sourceKey: source, id: "b"): ReviewRecord()]
        try ReviewStore.sealed(records: records, sealKey: key).write(to: url)
        let loaded = ReviewStore.load(from: url, sealKey: key)
        #expect(!loaded.tampered)
        #expect(loaded.records == records)
        #expect(loaded.records[ReviewStore.key(sourceKey: source, id: "a")]?.seen?.rev == 1)
        #expect(loaded.records[ReviewStore.key(sourceKey: source, id: "a")]?.pondAcceptPending == true)
        #expect(try object(url)["v"] as? Int == 1)
    }

    @Test func aMissingFileIsNoRecordsAndNotTampered() {
        let loaded = ReviewStore.load(from: tempFile(), sealKey: SymmetricKey(size: .bits256))
        #expect(loaded.records.isEmpty)
        #expect(!loaded.tampered)
    }

    @Test func aHandEditedAcceptedRevIsDropped() throws {
        let key = SymmetricKey(size: .bits256), url = tempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let name = ReviewStore.key(sourceKey: source, id: "a")
        try ReviewStore.sealed(records: [name: record(2), ReviewStore.key(sourceKey: source, id: "b"): ReviewRecord()],
                               sealKey: key).write(to: url)
        var file = try object(url)
        var records = try #require(file["records"] as? [String: Any])
        var entry = try #require(records[name] as? [String: Any])
        var inner = try #require(entry["record"] as? [String: Any])
        inner["accepted"] = ["rev": 3, "hash": String(repeating: "c", count: 64)]
        entry["record"] = inner
        records[name] = entry
        file["records"] = records
        try JSONSerialization.data(withJSONObject: file).write(to: url)

        let loaded = ReviewStore.load(from: url, sealKey: key)
        #expect(loaded.tampered)
        #expect(loaded.records[name] == nil)
        #expect(loaded.records[ReviewStore.key(sourceKey: source, id: "b")] == ReviewRecord())
    }

    @Test func aRecordCopiedToAnotherAskFails() throws {
        let key = SymmetricKey(size: .bits256), url = tempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let a = ReviewStore.key(sourceKey: source, id: "a"), b = ReviewStore.key(sourceKey: source, id: "b")
        try ReviewStore.sealed(records: [a: record()], sealKey: key).write(to: url)
        var file = try object(url)
        var records = try #require(file["records"] as? [String: Any])
        records[b] = records[a]
        file["records"] = records
        try JSONSerialization.data(withJSONObject: file).write(to: url)

        let loaded = ReviewStore.load(from: url, sealKey: key)
        #expect(loaded.tampered)
        #expect(loaded.records[a] == record())
        #expect(loaded.records[b] == nil)
    }

    @Test func anotherKeyOrAGarbledFileLoadsNothing() throws {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        try ReviewStore.sealed(records: [ReviewStore.key(sourceKey: source, id: "a"): record()],
                               sealKey: SymmetricKey(size: .bits256)).write(to: url)
        let other = ReviewStore.load(from: url, sealKey: SymmetricKey(size: .bits256))
        #expect(other.tampered && other.records.isEmpty)
        try Data("not json".utf8).write(to: url)
        let garbled = ReviewStore.load(from: url, sealKey: SymmetricKey(size: .bits256))
        #expect(garbled.tampered && garbled.records.isEmpty)
    }

    @Test func anOlderSealedFileReplayedGivesOnlyWhatItSealed() throws {
        let key = SymmetricKey(size: .bits256), url = tempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let name = ReviewStore.key(sourceKey: source, id: "a")
        let older = ReviewRecord(accepted: RevisionStamp(rev: 1, hash: String(repeating: "b", count: 64)),
                                 pins: [1: String(repeating: "b", count: 64)])
        let old = ReviewStore.sealed(records: [name: older], sealKey: key)
        try ReviewStore.sealed(records: [name: record(2)], sealKey: key).write(to: url)
        try old.write(to: url)   // the replay
        let loaded = ReviewStore.load(from: url, sealKey: key)
        #expect(!loaded.tampered)
        #expect(loaded.records[name] == older)
        #expect(loaded.records[name]?.accepted?.rev == 1)
    }

    @Test func theSealKeyIsMadeFreshOnceAndMarkedInTheReviewFile() throws {
        let secrets = MemorySecretStore(), url = tempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let first = try ReviewSeal.loadOrCreate(secrets, file: url)
        #expect(secrets.creates == 1)
        #expect(try object(url)["seal"] as? String == ReviewStore.sealID(first))
        let again = try ReviewSeal.loadOrCreate(secrets, file: url)
        #expect(secrets.creates == 1)
        #expect(first.withUnsafeBytes { Data($0) } == again.withUnsafeBytes { Data($0) })
        #expect(try ReviewSeal.load(secrets, file: url).map { $0.withUnsafeBytes { Data($0) } } == first.withUnsafeBytes { Data($0) })
        secrets.readError = .unreadable(-25293)
        #expect(throws: SecretStoreError.unreadable(-25293)) { try ReviewSeal.loadOrCreate(secrets, file: url) }
        #expect(secrets.creates == 1)
    }

    /// With the marker missing (no review file, one without `seal`, or one that doesn't decode),
    /// an item that is there isn't known to be Hook's: it is refused, never replaced, and
    /// nothing is written. Deleting `reviews.json` must not reset the records unasked.
    @Test func aSealItemWithoutHooksMarkerIsRefusedAndNothingIsWritten() throws {
        let planted = Data(repeating: 7, count: 32)
        let unmarked: Data = try {
            var file = try JSONSerialization.jsonObject(with: ReviewStore.sealed(
                records: [ReviewStore.key(sourceKey: source, id: "a"): record()], sealKey: SymmetricKey(data: planted))) as! [String: Any]
            file["seal"] = nil
            return try JSONSerialization.data(withJSONObject: file)
        }()
        let stores: [() -> MemorySecretStore] = [
            { MemorySecretStore([.reviewSeal: planted]) },
            { let s = MemorySecretStore(); s.plantForeign(.reviewSeal, planted); return s },
            { let s = MemorySecretStore([.reviewSeal: planted]); s.readError = .unreadable(-128); return s },
        ]
        for make in stores {
            for contents in [nil, unmarked, Data("not json".utf8)] {
                let secrets = make(), url = tempFile()
                defer { try? FileManager.default.removeItem(at: url) }
                try contents?.write(to: url)
                #expect(throws: SecretStoreError.foreign) { try ReviewSeal.open(secrets, file: url) }
                #expect(throws: SecretStoreError.foreign) { try ReviewSeal.loadOrCreate(secrets, file: url) }
                #expect(secrets.creates == 0)
                #expect(secrets.writes == 0)
                #expect(secrets.peek(.reviewSeal) == planted)
                #expect((try? Data(contentsOf: url)) == contents)
            }
        }
    }

    /// The deleted-file case end to end: a seal Hook made, then `reviews.json` gone.
    @Test func losingTheReviewFileLocksTheSealInsteadOfMintingANewOne() throws {
        let secrets = MemorySecretStore(), url = tempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let first = try ReviewSeal.loadOrCreate(secrets, file: url)
        try FileManager.default.removeItem(at: url)
        #expect(throws: SecretStoreError.foreign) { try ReviewSeal.open(secrets, file: url) }
        #expect(secrets.creates == 1)
        #expect(secrets.peek(.reviewSeal) == first.withUnsafeBytes { Data($0) })
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    /// The owner's reset: a fresh item over whatever is there, and a file naming it, with no records.
    @Test func createReplacesTheItemAndMarksTheNewSeal() throws {
        let planted = Data(repeating: 7, count: 32)
        let secrets = MemorySecretStore(), url = tempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        secrets.plantForeign(.reviewSeal, planted)
        let key = try ReviewSeal.create(secrets, file: url)
        #expect(key.withUnsafeBytes { Data($0) } != planted)
        #expect(secrets.peek(.reviewSeal) == key.withUnsafeBytes { Data($0) })
        #expect(secrets.creates == 1)
        #expect(try object(url)["seal"] as? String == ReviewStore.sealID(key))
        #expect(ReviewStore.load(from: url, sealKey: key).records.isEmpty)
        #expect(try ReviewSeal.open(secrets, file: url).created == false)
    }

    /// Once Hook has marked its seal, any other key in the item is refused, and left as it is.
    @Test func aSealItemThatIsntTheMarkedOneIsRefused() throws {
        let secrets = MemorySecretStore(), url = tempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        _ = try ReviewSeal.loadOrCreate(secrets, file: url)
        let planted = Data(repeating: 7, count: 32)
        try secrets.delete(.reviewSeal)
        try secrets.write(.reviewSeal, planted)
        let writes = secrets.writes
        #expect(throws: SecretStoreError.foreign) { try ReviewSeal.loadOrCreate(secrets, file: url) }
        #expect(throws: SecretStoreError.foreign) { try ReviewSeal.load(secrets, file: url) }
        #expect(secrets.writes == writes)
        #expect(secrets.peek(.reviewSeal) == planted)
        // So is one whose access list lets another app read it.
        secrets.plantForeign(.reviewSeal, planted)
        #expect(throws: SecretStoreError.foreign) { try ReviewSeal.loadOrCreate(secrets, file: url) }
    }
}
