import Foundation
import Testing
@testable import RelayCore

@Suite struct DisplayTypesTests {
    @Test func urgencyMapping() {
        #expect(Urgency(raw: "now") == .now)
        #expect(Urgency(raw: "today") == .today)
        #expect(Urgency(raw: "whenever") == .whenever)
        #expect(Urgency(raw: nil) == .today)
        #expect(Urgency(raw: "  ") == .today)
        #expect(Urgency(raw: "soon") == .unknown("soon"))
        #expect(Urgency(raw: "Now") == .unknown("Now"))
    }

    @Test func urgencyRankAndWord() {
        #expect([Urgency.now, .today, .unknown("soon"), .whenever].map(\.rank) == [0, 1, 1, 2])
        #expect([Urgency.now, .today, .whenever, .unknown("soon")].map(\.word) == ["Now", "Today", "Whenever", "soon"])
    }

    @Test func storedGroupingFallsBackToProject() {
        #expect(QueueGrouping(stored: "urgency") == .urgency)
        #expect(QueueGrouping(stored: "project") == .project)
        #expect(QueueGrouping(stored: nil) == .project)
        #expect(QueueGrouping(stored: "Urgency") == .project)
        #expect(QueueGrouping.allCases == [.project, .urgency])
    }

    @Test func summaryTexts() {
        #expect(RowSummary.steps(done: 2, total: 8).text == "2 of 8")
        #expect(RowSummary.choose(3).text == "Choose 1 of 3")
        #expect(RowSummary.reply.text == "Reply")
        #expect(RowSummary.legacyCmd.text == "1 step")
        #expect(RowSummary.legacyLink.text == "Link")
        #expect(RowSummary.none.text == "")
        #expect(RowSummary.steps(done: 1, total: 4).showsProgress)
        #expect(!RowSummary.steps(done: 0, total: 4).showsProgress)
        #expect(!RowSummary.reply.showsProgress)
    }

    @Test func stepLevelLabels() {
        #expect(StepLevel.letters == ["a", "b", "c", "d", "e", "f", "g", "h", "i", "j"])
        #expect(StepLevel.top(3).label == "3")
        #expect(StepLevel.sub(3, 1).label == "3b")
        #expect(StepLevel.sub(12, 9).label == "12j")
        #expect(StepLevel.verify.label == "Verify")
        #expect(StepLevel.sub(3, 0).isSub)
        #expect(!StepLevel.top(3).isSub && !StepLevel.verify.isSub)
    }

    @Test func smallValues() {
        #expect(PrimaryAction.done.title == "Done")
        #expect(PrimaryAction.sendAndDone.title == "Done")      // one Done; with something unsent it warns first
        #expect(UnsentKind.answer.caption == "You have an unsent answer")
        #expect(UnsentKind.reply.caption == "You have an unsent reply")
        #expect(HiddenCount.zero == HiddenCount(total: 0, now: 0))
        #expect(MenuProject(name: "Acme", open: 3).id == "Acme")
        #expect(SettingsTabID.allCases.map(\.rawValue) == ["general", "panel", "queue", "notifications", "connect"])
        let open = AskRowModel(id: "a", title: "T", project: "Acme", urgency: .now, created: "c", summary: .reply)
        #expect(open.isOpen && !open.hasDraft && open.resumeCommand == nil)
        var closed = open
        closed.closed = ClosedInfo(status: "done", closedBy: "owner", completedAt: nil)
        #expect(!closed.isOpen)
        #expect(StepContent(action: "Open").place == nil)
    }
}
