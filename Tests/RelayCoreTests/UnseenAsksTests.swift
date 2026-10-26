import Foundation
import Testing
@testable import RelayCore

@Suite struct UnseenAsksTests {
    @Test func arrivalWhileHiddenSetsTheDot() {
        var unseen = UnseenAsks()
        #expect(!unseen.showsDot)
        unseen.arrived(["a"], panelVisible: false)
        #expect(unseen.showsDot)
        #expect(unseen.ids == ["a"])
    }

    @Test func showingThePanelClearsIt() {
        var unseen = UnseenAsks()
        unseen.arrived(["a", "b"], panelVisible: false)
        unseen.panelShown()
        #expect(!unseen.showsDot)
    }

    @Test func arrivalWhileVisibleDoesNotSetIt() {
        var unseen = UnseenAsks()
        unseen.arrived(["a"], panelVisible: true)
        #expect(!unseen.showsDot)
    }

    @Test func seenAsksNeverBringItBack() {
        var unseen = UnseenAsks()
        unseen.arrived(["a"], panelVisible: false)
        unseen.panelShown()
        unseen.keep(open: ["a"])
        #expect(!unseen.showsDot)
    }

    @Test func aClosedUnseenAskNoLongerCounts() {
        var unseen = UnseenAsks()
        unseen.arrived(["a", "b"], panelVisible: false)
        unseen.keep(open: ["b", "c"])
        #expect(unseen.ids == ["b"])
        unseen.keep(open: ["c"])
        #expect(!unseen.showsDot)
    }

    @Test func aRestartKeepsUnseenAsksUnseen() throws {
        let suite = "UnseenAsksTests-\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let first = try #require(UserDefaults(suiteName: suite))
        var unseen = UnseenAsks.load(first)
        unseen.arrived(["a", "b"], panelVisible: false)
        unseen.save(first)

        let relaunched = try #require(UserDefaults(suiteName: suite))
        var restored = UnseenAsks.load(relaunched)
        #expect(restored.ids == ["a", "b"])
        #expect(restored.showsDot)

        restored.panelShown()
        restored.save(relaunched)
        #expect(UnseenAsks.load(relaunched) == UnseenAsks())
        #expect(relaunched.object(forKey: UnseenAsks.defaultsKey) == nil)
    }
}
