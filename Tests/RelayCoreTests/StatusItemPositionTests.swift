import Foundation
import Testing
@testable import RelayCore

@Suite struct StatusItemPositionTests {
    private func freshDefaults() -> UserDefaults {
        let name = "StatusItemPositionTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func seedsAPositionWhenNoneIsSaved() {
        let defaults = freshDefaults()
        StatusItemPosition.seedIfNeeded(defaults)
        #expect(defaults.double(forKey: StatusItemPosition.key) == StatusItemPosition.seed)
    }

    @Test func neverMovesAPositionTheUserChose() {
        let defaults = freshDefaults()
        defaults.set(612.0, forKey: StatusItemPosition.key)
        StatusItemPosition.seedIfNeeded(defaults)
        #expect(defaults.double(forKey: StatusItemPosition.key) == 612)
    }
}
