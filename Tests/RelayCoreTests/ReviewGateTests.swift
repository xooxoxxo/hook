import Foundation
import Testing
@testable import RelayCore

private let pond110 = PondVersion.semver(SemVer(major: 1, minor: 1, patch: 0))
private let pond100 = PondVersion.semver(SemVer(major: 1, minor: 0, patch: 0))

private func history(_ bodies: [Instructable]) throws -> VerifiedHistory {
    try #require(RevisionCheck.verify(revisedDetail(bodies))).get()
}

private func pins(_ h: VerifiedHistory) -> [Int: String] {
    h.stamps.mapValues(\.hash)
}

@Suite struct ReviewGateTests {
    @Test func noHistoryIsLegacy() {
        #expect(ReviewGate.resolve(record: nil, history: nil, pond: pond110) == .legacy)
        #expect(ReviewGate.resolve(record: ReviewRecord(), history: nil, pond: nil) == .legacy)
        #expect(!ReviewState.legacy.isLocked)
        #expect(ReviewState.legacy.action == nil)
    }

    @Test func aFailedHistoryIsHistoryChanged() {
        let state = ReviewGate.resolve(record: nil, history: .failure(.badHash(2)), pond: pond110)
        #expect(state == .historyChanged(.badHash(2)))
        #expect(state.isLocked)
        #expect(state.action == .trustHistory)
    }

    @Test func aPinViolationIsHistoryChanged() throws {
        let one = try history([idSteps(3)])
        let record = ReviewRecord(pins: [1: one.current.hash, 2: String(repeating: "f", count: 64)])
        #expect(ReviewGate.resolve(record: record, history: .success(one), pond: pond110) == .historyChanged(.rolledBack))
        let other = ReviewRecord(pins: [1: String(repeating: "f", count: 64)])
        #expect(ReviewGate.resolve(record: other, history: .success(one), pond: pond110) == .historyChanged(.rolledBack))
    }

    @Test func pinnedRev2ServedWithoutARevisionIsHistoryChanged() throws {
        let two = try history([idSteps(3), idSteps(4)])
        #expect(ReviewGate.resolve(record: ReviewRecord(pins: pins(two)), history: nil, pond: pond110)
            == .historyChanged(.missing))
        // Pinned at rev 1 only: never corrected, so an older Pond hides nothing.
        let one = try history([idSteps(3)])
        #expect(ReviewGate.resolve(record: ReviewRecord(pins: pins(one)), history: nil, pond: pond110) == .legacy)
    }

    @Test func aPondBelow110WithPinsIsHistoryChanged() throws {
        let two = try history([idSteps(3), idSteps(4)])
        let record = ReviewRecord(accepted: two.current, pins: pins(two))
        #expect(ReviewGate.resolve(record: record, history: .success(two), pond: pond100) == .historyChanged(.missing))
        #expect(ReviewGate.resolve(record: record, history: nil, pond: .legacy(protocol: 4)) == .historyChanged(.missing))
        // Unpinned on Pond 1.0.0: legacy. Pinned on 1.3.0: as usual.
        #expect(ReviewGate.resolve(record: nil, history: nil, pond: pond100) == .legacy)
        #expect(ReviewGate.resolve(record: record, history: .success(two), pond: .semver(SemVer(major: 1, minor: 3, patch: 0)))
            == .current(two.current))
    }

    @Test func rev1IsCurrent() throws {
        let one = try history([idSteps(3)])
        #expect(ReviewGate.resolve(record: nil, history: .success(one), pond: pond110) == .current(one.current))
        #expect(ReviewGate.renderedStamp(.current(one.current), history: one) == one.current)
    }

    @Test func acceptedCurrentIsCurrent() throws {
        let two = try history([idSteps(3), idSteps(4)])
        let record = ReviewRecord(accepted: two.current, pins: pins(two))
        #expect(ReviewGate.resolve(record: record, history: .success(two), pond: pond110) == .current(two.current))
    }

    @Test func rev2PinnedNeverSeenNeverAcceptedIsPendingWithoutABaseline() throws {
        let two = try history([idSteps(3), idSteps(4)])
        let state = ReviewGate.resolve(record: ReviewRecord(pins: pins(two)), history: .success(two), pond: pond110)
        #expect(state == .pending(shown: nil, current: two.current, baseline: nil))
        #expect(state.isLocked)
        #expect(state.action == .review(current: two.current))
        // The locked card and detail render rev 1.
        #expect(ReviewGate.renderedStamp(state, history: two) == two.stamps[1])
        #expect(ReviewGate.renderedBody(state, history: two)?.steps.count == 3)
    }

    @Test func seenRev1CurrentRev2IsPendingWithBaseline1() throws {
        let two = try history([idSteps(3), idSteps(4)])
        let record = ReviewRecord(seen: two.stamps[1], pins: pins(two))
        let state = ReviewGate.resolve(record: record, history: .success(two), pond: pond110)
        #expect(state == .pending(shown: two.stamps[1], current: two.current, baseline: 1))
    }

    @Test func acceptedWinsOverSeen() throws {
        let three = try history([idSteps(3), idSteps(4), idSteps(5)])
        let record = ReviewRecord(accepted: three.stamps[2], seen: three.stamps[1], pins: pins(three))
        let state = ReviewGate.resolve(record: record, history: .success(three), pond: pond110)
        #expect(state == .pending(shown: three.stamps[2], current: three.current, baseline: 2))
        #expect(ReviewGate.renderedBody(state, history: three)?.steps.count == 4)
    }

    @Test func aStampTheHistoryNoLongerHoldsIsNotShown() throws {
        let two = try history([idSteps(3), idSteps(4)])
        let stale = RevisionStamp(rev: 1, hash: String(repeating: "e", count: 64))
        let record = ReviewRecord(accepted: stale, pins: [:])
        #expect(ReviewGate.resolve(record: record, history: .success(two), pond: pond110)
            == .pending(shown: nil, current: two.current, baseline: nil))
    }

    @Test func aListedHistoryWithoutRev1RendersNothingYet() throws {
        let detail = revisedDetail([idSteps(3), idSteps(4)])
        let listed = try #require(RevisionCheck.verify(listed: detail.item)).get()
        let state = ReviewGate.resolve(record: nil, history: .success(listed), pond: pond110)
        #expect(ReviewGate.renderedStamp(state, history: listed) == nil)
        #expect(ReviewGate.renderedStamp(.historyChanged(.missing), history: listed) == nil)
        #expect(ReviewGate.renderedStamp(.legacy, history: nil) == nil)
    }
}
