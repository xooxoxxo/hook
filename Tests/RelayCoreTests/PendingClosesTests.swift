import Foundation
import Testing
@testable import RelayCore

private let t0 = Date(timeIntervalSince1970: 1_791_000_000)

@Suite struct PendingClosesTests {
    @Test func startsEmpty() {
        var p = PendingCloses()
        #expect(p.isEmpty)
        #expect(p.latest == nil)
        #expect(!p.contains("a"))
        #expect(p.undo("a") == nil)
        #expect(p.undoLatest() == nil)
        #expect(p.due(now: t0).isEmpty)
        #expect(p.drainAll().isEmpty)
        #expect(PendingCloses.delay == 10)
    }

    @Test func addSetsTheDeadline() {
        var p = PendingCloses()
        p.add(id: "a", verdict: .done, note: "ok", title: "Rotate", now: t0)
        #expect(!p.isEmpty)
        #expect(p.contains("a"))
        #expect(p.latest == PendingClose(id: "a", verdict: .done, note: "ok", title: "Rotate",
                                         deadline: t0.addingTimeInterval(10)))
    }

    @Test func latestIsTheMostRecentlyAdded() {
        var p = PendingCloses()
        p.add(id: "a", verdict: .done, note: nil, title: "A", now: t0)
        p.add(id: "b", verdict: .declined, note: nil, title: "B", now: t0.addingTimeInterval(1))
        #expect(p.latest?.id == "b")
        p.add(id: "a", verdict: .declined, note: nil, title: "A", now: t0.addingTimeInterval(2))
        #expect(p.latest?.id == "a")
    }

    @Test func reAddReplacesVerdictAndDeadline() {
        var p = PendingCloses()
        p.add(id: "a", verdict: .done, note: "first", title: "A", now: t0)
        p.add(id: "a", verdict: .declined, note: nil, title: "A", now: t0.addingTimeInterval(5))
        let all = p.drainAll()
        #expect(all.count == 1)
        #expect(all.first?.verdict == .declined)
        #expect(all.first?.note == nil)
        #expect(all.first?.deadline == t0.addingTimeInterval(15))
    }

    @Test func undoRemovesAndReturns() {
        var p = PendingCloses()
        p.add(id: "a", verdict: .done, note: nil, title: "A", now: t0)
        p.add(id: "b", verdict: .done, note: nil, title: "B", now: t0)
        #expect(p.undo("a")?.id == "a")
        #expect(!p.contains("a"))
        #expect(p.undo("a") == nil)
        #expect(p.contains("b"))
    }

    @Test func undoLatestPopsInReverseOrder() {
        var p = PendingCloses()
        p.add(id: "a", verdict: .done, note: nil, title: "A", now: t0)
        p.add(id: "b", verdict: .done, note: nil, title: "B", now: t0.addingTimeInterval(1))
        #expect(p.undoLatest()?.id == "b")
        #expect(p.latest?.id == "a")
        #expect(p.undoLatest()?.id == "a")
        #expect(p.isEmpty)
    }

    @Test func dueReturnsOnlyExpiredOldestFirst() {
        var p = PendingCloses()
        p.add(id: "late", verdict: .done, note: nil, title: "L", now: t0.addingTimeInterval(3))
        p.add(id: "early", verdict: .done, note: nil, title: "E", now: t0)
        p.add(id: "later", verdict: .declined, note: nil, title: "X", now: t0.addingTimeInterval(8))
        #expect(p.due(now: t0.addingTimeInterval(9.9)).isEmpty)
        // A deadline equal to now is due.
        #expect(p.due(now: t0.addingTimeInterval(10)).map(\.id) == ["early"])
        #expect(p.due(now: t0.addingTimeInterval(14)).map(\.id) == ["late"])
        #expect(p.contains("later"))
        #expect(p.due(now: t0.addingTimeInterval(100)).map(\.id) == ["later"])
        #expect(p.isEmpty)
    }

    @Test func dueOrdersByDeadlineNotInsertion() {
        var p = PendingCloses()
        p.add(id: "a", verdict: .done, note: nil, title: "A", now: t0)
        p.add(id: "b", verdict: .done, note: nil, title: "B", now: t0.addingTimeInterval(1))
        p.add(id: "a", verdict: .done, note: nil, title: "A", now: t0.addingTimeInterval(2))   // a now ends last
        #expect(p.due(now: t0.addingTimeInterval(20)).map(\.id) == ["b", "a"])
    }

    @Test func drainAllEmptiesOldestFirst() {
        var p = PendingCloses()
        p.add(id: "b", verdict: .done, note: nil, title: "B", now: t0.addingTimeInterval(4))
        p.add(id: "a", verdict: .declined, note: "n", title: "A", now: t0)
        p.add(id: "c", verdict: .done, note: nil, title: "C", now: t0.addingTimeInterval(4))
        #expect(p.drainAll().map(\.id) == ["a", "b", "c"])
        #expect(p.isEmpty)
        #expect(p.drainAll().isEmpty)
    }
}
