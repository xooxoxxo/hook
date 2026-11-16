import Foundation
import Testing
@testable import RelayCore

/// The queue card's "+N steps": steps added to an ask the owner hasn't opened since.
@Suite struct UnseenAppendsTests {
    @Test func addedAccumulates() {
        var unseen = UnseenAppends()
        unseen.added("a", steps: 2)
        unseen.added("a", steps: 1)
        unseen.added("b", steps: 1)
        #expect(unseen.counts == ["a": 3, "b": 1])
        unseen.added("c", steps: 0)
        #expect(unseen.counts["c"] == nil)
    }

    @Test func openedClears() {
        var unseen = UnseenAppends()
        unseen.added("a", steps: 2)
        unseen.added("b", steps: 1)
        unseen.opened("a")
        #expect(unseen.counts == ["b": 1])
        unseen.opened("zzz")
        #expect(unseen.counts == ["b": 1])
    }

    @Test func keepDropsClosed() {
        var unseen = UnseenAppends()
        unseen.added("a", steps: 2)
        unseen.added("b", steps: 1)
        unseen.keep(open: ["b", "c"])
        #expect(unseen.counts == ["b": 1])
    }

    @Test func roundTrip() throws {
        let suite = "UnseenAppendsTests-\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let defaults = try #require(UserDefaults(suiteName: suite))
        var unseen = UnseenAppends.load(defaults)
        #expect(unseen == UnseenAppends())
        unseen.added("a", steps: 2)
        unseen.save(defaults)
        #expect(UnseenAppends.load(defaults).counts == ["a": 2])
        unseen.opened("a")
        unseen.save(defaults)
        #expect(defaults.object(forKey: UnseenAppends.defaultsKey) == nil)
        // A value that isn't a count map reads as none.
        defaults.set(["a": "two", "b": 1], forKey: UnseenAppends.defaultsKey)
        #expect(UnseenAppends.load(defaults).counts == ["b": 1])
        #expect(UnseenAppends.defaultsKey == "relay.queue.unseenAppends")
    }

    @Test func theTagText() {
        #expect(UnseenAppends.tag(1) == "+1 step")
        #expect(UnseenAppends.tag(2) == "+2 steps")
    }
}

/// Which append markers are new since the Store last looked at an ask.
@Suite struct AppendWatchTests {
    private func marker(_ rev: Int, added: Int = 1) -> AppendMarker {
        AppendMarker(rev: rev, at: "2026-11-14T10:0\(rev):00+00:00", note: "Note \(rev)", firstStepID: "r\(rev)",
                     addedTopLevel: added, afterAnswer: false, firstStepIndex: rev)
    }

    @Test func theFirstLookIsNeverNew() {
        var watch = AppendWatch()
        #expect(watch.observe("a", markers: [marker(2), marker(3)]).isEmpty)
        #expect(watch.observe("a", markers: [marker(2), marker(3)]).isEmpty)
        #expect(watch.observe("a", markers: [marker(2), marker(3), marker(4, added: 2)]).map(\.rev) == [4])
        #expect(watch.observe("b", markers: []).isEmpty)
        #expect(watch.observe("b", markers: [marker(2)]).map(\.rev) == [2])
    }

    @Test func aMarkerIsNewOnce() {
        var watch = AppendWatch()
        _ = watch.observe("a", markers: [])
        #expect(watch.observe("a", markers: [marker(2), marker(3)]).map(\.rev) == [2, 3])
        #expect(watch.observe("a", markers: [marker(2), marker(3)]).isEmpty)
        // A correction starts a new run: the old markers go, and none is new until a later rev.
        #expect(watch.observe("a", markers: []).isEmpty)
        #expect(watch.observe("a", markers: [marker(3)]).isEmpty)
        #expect(watch.observe("a", markers: [marker(5)]).map(\.rev) == [5])
    }

    @Test func forgetStartsOver() {
        var watch = AppendWatch()
        _ = watch.observe("a", markers: [])
        watch.forget()
        #expect(watch.observe("a", markers: [marker(2)]).isEmpty)
    }
}
