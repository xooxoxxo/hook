import Foundation
import Testing
@testable import RelayCore

@Suite struct SecretStoreTests {
    private let name = SecretName.ownerKey(sourceKey: "mailbox:pond.example:8790#personal")

    @Test func aRoundTrip() throws {
        let store = MemorySecretStore()
        #expect(try store.read(name) == nil)
        try store.write(name, Data("one".utf8))
        #expect(try store.read(name) == Data("one".utf8))
        try store.write(name, Data("two".utf8))
        #expect(try store.read(name) == Data("two".utf8))
        #expect(try store.read(.reviewSeal) == nil)
        try store.delete(name)
        #expect(try store.read(name) == nil)
        try store.delete(name)      // a missing item deletes quietly
        #expect(store.writes == 2)
    }

    @Test func aRefusedStoreThrowsAndKeepsItsItems() throws {
        let store = MemorySecretStore([name: Data("kept".utf8)])
        store.readError = .unreadable(-128)
        #expect(throws: SecretStoreError.unreadable(-128)) { try store.read(name) }
        store.writeError = .writeFailed(-25308)
        #expect(throws: SecretStoreError.writeFailed(-25308)) { try store.write(name, Data("new".utf8)) }
        store.deleteError = .deleteFailed(-25308)
        #expect(throws: SecretStoreError.deleteFailed(-25308)) { try store.delete(name) }
        #expect(store.peek(name) == Data("kept".utf8))
    }

    @Test func aForeignItemIsNeitherReadNorUpdated() throws {
        let store = MemorySecretStore()
        store.plantForeign(.reviewSeal, Data(repeating: 7, count: 32))
        #expect(throws: SecretStoreError.foreign) { try store.read(.reviewSeal) }
        #expect(throws: SecretStoreError.foreign) { try store.write(.reviewSeal, Data(repeating: 1, count: 32)) }
        #expect(store.peek(.reviewSeal) == Data(repeating: 7, count: 32))
        #expect(store.writes == 0)
        // Other items are unaffected.
        try store.write(name, Data("one".utf8))
        #expect(try store.read(name) == Data("one".utf8))
    }

    @Test func onlyAnAccessListNamingThisAppAloneIsOwn() {
        let me = Data("/Applications/Hook.app".utf8), other = Data("/usr/bin/security".utf8)
        #expect(KeychainSecretStore.isOwn(decryptLists: [[me]], me: me))
        #expect(KeychainSecretStore.isOwn(decryptLists: [[me, me]], me: me))
        // Any app may read (security add-generic-password -A).
        #expect(!KeychainSecretStore.isOwn(decryptLists: [nil], me: me))
        #expect(!KeychainSecretStore.isOwn(decryptLists: [[me], nil], me: me))
        // Made for another app, or shared with one.
        #expect(!KeychainSecretStore.isOwn(decryptLists: [[other]], me: me))
        #expect(!KeychainSecretStore.isOwn(decryptLists: [[me, other]], me: me))
        // No entry that reads, or one that names no app: not what Hook makes.
        #expect(!KeychainSecretStore.isOwn(decryptLists: [], me: me))
        #expect(!KeychainSecretStore.isOwn(decryptLists: [[]], me: me))
    }

    @Test func createReplacesWhateverIsThere() throws {
        let store = MemorySecretStore()
        store.plantForeign(.reviewSeal, Data(repeating: 7, count: 32))
        try store.create(.reviewSeal, Data(repeating: 1, count: 32))
        #expect(try store.read(.reviewSeal) == Data(repeating: 1, count: 32))
        #expect(store.creates == 1)
    }

    // MARK: The Keychain's rules, on a fake

    @Test func aReadChecksAndReadsTheOneItemItFound() throws {
        let keychain = FakeKeychain()
        keychain.put(name, Data("mine".utf8))
        let rules = KeychainRules(ops: keychain)
        #expect(try rules.read(name) == Data("mine".utf8))
        #expect(keychain.calls == ["find", "isOwn 1", "data 1"])
        // Swapped for a planted item right after the check: the read is of the checked item,
        // which is gone, never of the planted one.
        keychain.calls = []
        keychain.afterCheck = { keychain.put(name, Data("planted".utf8), own: false) }
        #expect(throws: SecretStoreError.unreadable(errSecInvalidItemRef)) { try rules.read(name) }
        #expect(keychain.calls == ["find", "isOwn 1", "data 1"])
    }

    @Test func aWriteUpdatesTheCheckedItemInPlace() throws {
        let keychain = FakeKeychain()
        keychain.put(name, Data("one".utf8))
        let rules = KeychainRules(ops: keychain)
        try rules.write(name, Data("two".utf8))
        #expect(keychain.calls == ["find", "isOwn 1", "update 1"])
        #expect(keychain.items[1]?.data == Data("two".utf8))
    }

    @Test func aWriteWithNoItemOnlyAdds() throws {
        let keychain = FakeKeychain()
        let rules = KeychainRules(ops: keychain)
        try rules.write(name, Data("one".utf8))
        #expect(keychain.calls == ["find", "add"])
        // One planted between the lookup and the add fails the add; nothing is updated.
        let raced = FakeKeychain()
        raced.afterFind = { raced.put(name, Data("planted".utf8), own: false) }
        #expect(throws: SecretStoreError.writeFailed(errSecDuplicateItem)) {
            try KeychainRules(ops: raced).write(name, Data("one".utf8))
        }
        #expect(raced.calls == ["find", "add"])
    }

    @Test func aForeignItemIsNeitherReadNorUpdatedByTheRules() throws {
        let keychain = FakeKeychain()
        keychain.put(name, Data("planted".utf8), own: false)
        let rules = KeychainRules(ops: keychain)
        #expect(throws: SecretStoreError.foreign) { try rules.read(name) }
        #expect(throws: SecretStoreError.foreign) { try rules.write(name, Data("key".utf8)) }
        #expect(keychain.calls == ["find", "isOwn 1", "find", "isOwn 1"])
        #expect(keychain.items[1]?.data == Data("planted".utf8))
    }

    /// A new secret never lands in an item that was already there, Hook's or planted.
    @Test func createDeletesThenAddsFresh() throws {
        let keychain = FakeKeychain()
        keychain.put(name, Data("planted".utf8), own: false)
        let rules = KeychainRules(ops: keychain)
        try rules.create(name, Data("key".utf8))
        #expect(keychain.calls == ["delete", "add"])
        #expect(keychain.items[1] == nil)
        #expect(keychain.items[2]?.data == Data("key".utf8))
        #expect(keychain.items[2]?.own == true)
        // One planted between the delete and the add: the add fails, nothing is written into it.
        let raced = FakeKeychain()
        raced.afterDelete = { raced.put(name, Data("planted".utf8), own: false) }
        #expect(throws: SecretStoreError.writeFailed(errSecDuplicateItem)) {
            try KeychainRules(ops: raced).create(name, Data("key".utf8))
        }
        #expect(raced.items.values.map(\.data) == [Data("planted".utf8)])
    }

    @Test func theNamesHookUses() {
        #expect(name.service == "io.github.xooxoxxo.relay.owner-key")
        #expect(name.account == "mailbox:pond.example:8790#personal")
        #expect(name.label == "Hook owner key")
        #expect(SecretName.reviewSeal == SecretName(service: "io.github.xooxoxxo.relay.review-seal", account: "default"))
        #expect(SecretName.reviewSeal.label == "Hook review seal")
    }
}

/// A Keychain in memory, by item number. `put` replaces any item with the name, as a delete
/// and an add would; the hooks run right after a lookup, a check or a delete, to race them.
private final class FakeKeychain: KeychainOps, @unchecked Sendable {
    struct Entry: Equatable {
        var name: SecretName
        var data: Data
        var own: Bool
    }

    var items: [Int: Entry] = [:]
    var calls: [String] = []
    var afterFind: (() -> Void)?
    var afterCheck: (() -> Void)?
    var afterDelete: (() -> Void)?
    private var next = 1

    func put(_ name: SecretName, _ data: Data, own: Bool = true) {
        items = items.filter { $0.value.name != name }
        items[next] = Entry(name: name, data: data, own: own)
        next += 1
    }

    func find(_ name: SecretName) throws -> Int? {
        calls.append("find")
        defer { afterFind?(); afterFind = nil }
        return items.first { $0.value.name == name }?.key
    }

    func isOwn(_ item: Int) throws -> Bool {
        calls.append("isOwn \(item)")
        defer { afterCheck?(); afterCheck = nil }
        return items[item]?.own ?? false
    }

    func data(_ item: Int) throws -> Data {
        calls.append("data \(item)")
        guard let entry = items[item] else { throw SecretStoreError.unreadable(errSecInvalidItemRef) }
        return entry.data
    }

    func update(_ item: Int, _ data: Data) throws {
        calls.append("update \(item)")
        guard items[item] != nil else { throw SecretStoreError.writeFailed(errSecInvalidItemRef) }
        items[item]?.data = data
    }

    func add(_ name: SecretName, _ data: Data) throws {
        calls.append("add")
        guard !items.values.contains(where: { $0.name == name }) else {
            throw SecretStoreError.writeFailed(errSecDuplicateItem)
        }
        put(name, data)
    }

    func delete(_ name: SecretName) throws {
        calls.append("delete")
        items = items.filter { $0.value.name != name }
        afterDelete?()
        afterDelete = nil
    }
}
