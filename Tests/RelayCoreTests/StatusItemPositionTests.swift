import Foundation
import Testing
@testable import RelayCore

/// An in-memory store, so the tests never write a preferences file.
private final class MemoryStore: PositionStore {
    var values: [String: Any] = [:]
    func object(forKey defaultName: String) -> Any? { values[defaultName] }
    func set(_ value: Double, forKey defaultName: String) { values[defaultName] = value }
}

@Suite struct StatusItemPositionTests {
    @Test func seedsAPositionWhenNoneIsSaved() {
        let store = MemoryStore()
        StatusItemPosition.seedIfNeeded(store)
        #expect(store.values[StatusItemPosition.key] as? Double == StatusItemPosition.seed)
    }

    @Test func neverMovesAPositionTheUserChose() {
        let store = MemoryStore()
        store.values[StatusItemPosition.key] = 612.0
        StatusItemPosition.seedIfNeeded(store)
        #expect(store.values[StatusItemPosition.key] as? Double == 612)
    }
}
