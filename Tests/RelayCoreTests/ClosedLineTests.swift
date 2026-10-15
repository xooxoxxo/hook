import Foundation
import Testing
@testable import RelayCore

private let closedAt = "2026-10-11T09:30:00+00:00"
private let base = Timestamp.date(closedAt)!

@Suite struct ClosedLineTests {
    @Test func doneByTheOwner() {
        let text = ClosedLine.text(status: "done", closedBy: "owner", completedAt: closedAt,
                                   now: base.addingTimeInterval(5 * 60 + 20))
        #expect(text == "Done 5m ago")
    }

    @Test func skippedWithUnknownActor() {
        let text = ClosedLine.text(status: "dismissed", closedBy: nil, completedAt: closedAt,
                                   now: base.addingTimeInterval(3600 + 59))
        #expect(text == "Skipped 1h ago")
    }

    @Test func closedByTheSessionWinsOverStatus() {
        for status in ["done", "dismissed"] {
            let text = ClosedLine.text(status: status, closedBy: "session", completedAt: closedAt,
                                       now: base.addingTimeInterval(2 * 3600))
            #expect(text == "Closed by the session 2h ago")
        }
    }

    @Test func justNowAndClockSkew() {
        #expect(ClosedLine.text(status: "done", closedBy: "owner", completedAt: closedAt,
                                now: base.addingTimeInterval(59)) == "Done just now")
        #expect(ClosedLine.text(status: "done", closedBy: "owner", completedAt: closedAt,
                                now: base.addingTimeInterval(-300)) == "Done just now")
    }

    @Test func daysAndMissingTime() {
        #expect(ClosedLine.text(status: "done", closedBy: nil, completedAt: closedAt,
                                now: base.addingTimeInterval(86400 * 2)) == "Done 2d ago")
        #expect(ClosedLine.text(status: "done", closedBy: nil, completedAt: nil, now: base) == "Done")
        #expect(ClosedLine.text(status: "dismissed", closedBy: nil, completedAt: "yesterday", now: base) == "Skipped")
        #expect(ClosedLine.text(status: "open", closedBy: nil, completedAt: nil, now: base) == "Closed")
    }
}
