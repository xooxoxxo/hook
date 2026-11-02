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

    @Test func theNamesHookUses() {
        #expect(name.service == "io.github.xooxoxxo.relay.owner-key")
        #expect(name.account == "mailbox:pond.example:8790#personal")
        #expect(name.label == "Hook owner key")
        #expect(SecretName.reviewSeal == SecretName(service: "io.github.xooxoxxo.relay.review-seal", account: "default"))
        #expect(SecretName.reviewSeal.label == "Hook review seal")
    }
}
