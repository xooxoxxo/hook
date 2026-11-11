import CryptoKit
import Foundation
import Security
import Testing
@testable import RelayCore

/// Exercises query policy without accessing the developer's Keychain.
final class FakeDataProtectionSecurity: DataProtectionSecurityAPI, @unchecked Sendable {
    private let lock = NSLock()
    var items: [SecretName: Data] = [:]
    var queries: [[String: Any]] = []
    var readStatus: OSStatus = errSecSuccess
    var addStatus: OSStatus = errSecSuccess
    var updateStatus: OSStatus = errSecSuccess
    var deleteStatus: OSStatus = errSecSuccess
    var onAdd: (@Sendable () -> Void)?

    func copyMatching(_ query: [String: Any]) -> (status: OSStatus, data: Data?) {
        lock.lock(); defer { lock.unlock() }
        queries.append(query)
        guard readStatus == errSecSuccess else { return (readStatus, nil) }
        guard let data = items[name(query)] else { return (errSecItemNotFound, nil) }
        return (errSecSuccess, data)
    }
    func add(_ query: [String: Any]) -> OSStatus {
        onAdd?()
        lock.lock(); defer { lock.unlock() }
        queries.append(query)
        guard addStatus == errSecSuccess else { return addStatus }
        let name = name(query)
        guard items[name] == nil else { return errSecDuplicateItem }
        items[name] = query[kSecValueData as String] as? Data
        return errSecSuccess
    }
    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
        lock.lock(); defer { lock.unlock() }
        queries.append(query)
        guard updateStatus == errSecSuccess else { return updateStatus }
        let name = name(query)
        guard items[name] != nil else { return errSecItemNotFound }
        items[name] = attributes[kSecValueData as String] as? Data
        return errSecSuccess
    }
    func delete(_ query: [String: Any]) -> OSStatus {
        lock.lock(); defer { lock.unlock() }
        queries.append(query)
        guard deleteStatus == errSecSuccess else { return deleteStatus }
        return items.removeValue(forKey: name(query)) == nil ? errSecItemNotFound : errSecSuccess
    }
    private func name(_ query: [String: Any]) -> SecretName {
        SecretName(service: query[kSecAttrService as String] as! String, account: query[kSecAttrAccount as String] as! String)
    }
}

@Suite struct DataProtectionSecretStoreTests {
    private let name = SecretName.reviewSeal

    @Test func queryPolicyUsesDataProtectionDeviceOnlyAndNeverSynchronizable() throws {
        for accessibility in [DataProtectionSecretStore.Accessibility.afterFirstUnlockThisDeviceOnly, .whenUnlockedThisDeviceOnly] {
            let api = FakeDataProtectionSecurity()
            let store = DataProtectionSecretStore(accessibility: accessibility, security: api)
            #expect(try store.read(name) == nil)
            try store.create(name, Data([1]))
            #expect(try store.read(name) == Data([1]))
            try store.write(name, Data([2]))
            #expect(try store.read(name) == Data([2]))
            try store.delete(name)
            try store.delete(name)
            for query in api.queries {
                #expect(query[kSecUseDataProtectionKeychain as String] as? Bool == true)
                #expect(query[kSecClass as String] as? String == kSecClassGenericPassword as String)
                #expect(query[kSecAttrSynchronizable as String] == nil)
                #expect(query[kSecAttrAccess as String] == nil)
            }
            let add = try #require(api.queries.first { $0[kSecValueData as String] != nil })
            let expected = accessibility == .afterFirstUnlockThisDeviceOnly ? kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly : kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            #expect(add[kSecAttrAccessible as String] as? String == expected as String)
        }
    }

    @Test func createOnDuplicateNeverDeletesOrReplacesTheSeal() throws {
        let api = FakeDataProtectionSecurity()
        api.items[name] = Data([7])
        let store = DataProtectionSecretStore(accessibility: .whenUnlockedThisDeviceOnly, security: api)
        #expect(throws: SecretStoreError.writeFailed(errSecDuplicateItem)) { try store.create(name, Data([9])) }
        #expect(api.items[name] == Data([7]))
        #expect(api.queries.count == 1)
    }

    @Test func explicitReplacementAndOwnerReEnrollmentWorkButRefuseUnreadableItems() throws {
        let api = FakeDataProtectionSecurity()
        let store = DataProtectionSecretStore(accessibility: .whenUnlockedThisDeviceOnly, security: api)
        let seal = SymmetricKey(data: Data(repeating: 1, count: 32))
        try OwnerKeyVault.create(OwnerKeyRecord(key: "old", status: .refused, scheme: "https"), store, sourceKey: "pond", seal: seal)
        try OwnerKeyVault.create(OwnerKeyRecord(key: "new", status: .pending, scheme: "https"), store, sourceKey: "pond", seal: seal)
        #expect(try OwnerKeyVault.record(store, sourceKey: "pond", seal: seal)?.key == "new")
        let old = api.items
        api.readStatus = errSecInteractionNotAllowed
        #expect(throws: SecretStoreError.unreadable(errSecInteractionNotAllowed)) {
            try OwnerKeyVault.create(OwnerKeyRecord(key: "lost", status: .pending), store, sourceKey: "pond", seal: seal)
        }
        #expect(api.items == old)
    }

    @Test func lockedAndCorruptSealsRetainReviewRecordsAndCorrectedAsksStayLocked() throws {
        let api = FakeDataProtectionSecurity()
        let store = DataProtectionSecretStore(accessibility: .whenUnlockedThisDeviceOnly, security: api)
        let file = FileManager.default.temporaryDirectory.appending(path: "hook-reviews-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let key = try ReviewSeal.loadOrCreate(store, file: file)
        let current = RevisionStamp(rev: 2, hash: "h2")
        let record = ReviewRecord(accepted: current, seen: current, pins: [2: "h2"])
        try ReviewStore.sealed(records: ["pond|ask": record], sealKey: key).write(to: file)
        let records = try Data(contentsOf: file)
        let original = api.items[name]
        api.readStatus = errSecInteractionNotAllowed
        #expect(throws: SecretStoreError.unreadable(errSecInteractionNotAllowed)) { try ReviewSeal.open(store, file: file) }
        #expect(throws: SecretStoreError.unreadable(errSecInteractionNotAllowed)) { try ReviewSeal.create(store, file: file) }
        #expect(api.items[name] == original)
        #expect(try Data(contentsOf: file) == records)
        #expect(ReviewState.waitingForKeychain(current: current).isLocked)
        api.readStatus = errSecSuccess
        api.items[name] = Data([0xff])
        #expect(throws: SecretStoreError.foreign) { try ReviewSeal.open(store, file: file) }
        #expect(api.items[name] == Data([0xff]))
        #expect(try Data(contentsOf: file) == records)
        #expect(ReviewGate.resolve(record: nil, history: .failure(.missing), pond: nil).isLocked)
        let reset = try ReviewSeal.create(store, file: file)
        #expect(ReviewStore.load(from: file, sealKey: reset).records.isEmpty)
        #expect(try ReviewSeal.open(store, file: file).created == false)
    }

    @Test func aRacingSealCreationFailsWithoutChangingExistingRecords() throws {
        let api = FakeDataProtectionSecurity()
        let store = DataProtectionSecretStore(accessibility: .whenUnlockedThisDeviceOnly, security: api)
        let file = FileManager.default.temporaryDirectory.appending(path: "hook-reviews-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let bytes = Data("existing review records".utf8)
        try bytes.write(to: file)
        api.onAdd = { api.items[.reviewSeal] = Data([7]) }
        #expect(throws: SecretStoreError.writeFailed(errSecDuplicateItem)) { try ReviewSeal.open(store, file: file) }
        #expect(api.items[name] == Data([7]))
        #expect(try Data(contentsOf: file) == bytes)
    }

    @Test func missingIsTheOnlyNilReadAndStatusFailuresAreTyped() throws {
        let api = FakeDataProtectionSecurity()
        let store = DataProtectionSecretStore(accessibility: .whenUnlockedThisDeviceOnly, security: api)
        #expect(try store.read(name) == nil)
        api.readStatus = errSecAuthFailed
        #expect(throws: SecretStoreError.unreadable(errSecAuthFailed)) { try store.read(name) }
        api.addStatus = errSecNotAvailable
        #expect(throws: SecretStoreError.writeFailed(errSecNotAvailable)) { try store.create(name, Data()) }
        api.deleteStatus = errSecInteractionNotAllowed
        #expect(throws: SecretStoreError.deleteFailed(errSecInteractionNotAllowed)) { try store.delete(name) }
    }
}
