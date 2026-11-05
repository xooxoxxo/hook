import RelayCore
import Testing
@testable import RelayUI

@Suite @MainActor struct StepRowTests {
    @Test func whichRowsOpen() {
        #expect(StepRow.isOpen(state: .current, locked: false, expanded: false))
        #expect(!StepRow.isOpen(state: .done, locked: false, expanded: false))
        #expect(StepRow.isOpen(state: .done, locked: false, expanded: true))
        #expect(!StepRow.isOpen(state: .todo, locked: false, expanded: false))
        #expect(StepRow.isOpen(state: .todo, locked: false, expanded: true))
        #expect(!StepRow.isOpen(state: .todo, locked: true, expanded: true))      // a locked row never opens
        #expect(!StepRow.isExpandable(state: .current, locked: false))
        #expect(!StepRow.isExpandable(state: .todo, locked: true))
        #expect(StepRow.isExpandable(state: .done, locked: false) && StepRow.isExpandable(state: .todo, locked: false))
    }

    /// Report sits at the bottom right of an expanded, actionable, unreported row whose field
    /// isn't open; a row that can't expand offers it from its context menu.
    @Test(arguments: [false, true], [false, true])
    func reportLinkOnlyOnExpandedActionableUnreported(reported: Bool, targeted: Bool) {
        for open in [false, true] {
            for actionable in [false, true] {
                for locked in [false, true] {
                    for allowed in [false, true] {
                        let slot = StepReportSlot(allowed: allowed, actionable: actionable, reported: reported,
                                                  targeted: targeted, state: .idle, keyReady: true, limits: .old)
                        let expected = allowed && actionable && open && !locked && !reported && !targeted
                        #expect(StepRow.showsReportLink(slot, open: open, locked: locked) == expected,
                                "open \(open) actionable \(actionable) locked \(locked) allowed \(allowed)")
                        // The field shows while its slot is targeted, even on a collapsed row.
                        #expect(StepRow.showsReportField(slot) == (allowed && targeted))
                    }
                }
            }
        }
        #expect(StepRow.reportsFromMenu(allowed: true, actionable: true, expandable: false, locked: false))
        #expect(!StepRow.reportsFromMenu(allowed: true, actionable: true, expandable: true, locked: false))
        #expect(!StepRow.reportsFromMenu(allowed: false, actionable: true, expandable: false, locked: false))
        #expect(!StepRow.reportsFromMenu(allowed: true, actionable: true, expandable: false, locked: true))
    }

    /// A reported step shows only the icon: no link, whether open or not.
    @Test func reportedRowShowsOnlyIcon() {
        let slot = StepReportSlot(allowed: true, actionable: true, reported: true, targeted: false, state: .idle,
                                  keyReady: true, limits: .old)
        #expect(!StepRow.showsReportLink(slot, open: true, locked: false))
        #expect(!StepRow.showsReportField(slot))
        #expect(ProblemReport.reportedHelp == "Reported. Waiting for a correction.")
    }

    @Test func theReportSlotsFollowThePaths() {
        let reports = StepReports(allowed: true, actionable: ["1", "2"], reported: ["1"], target: "2", onReport: { _ in })
        #expect(reports.slot("2").state == .idle && reports.slot("2").limits == .old)
        #expect(reports.slot("1").reported == true)
        #expect(reports.slot("1").targeted == false)
        #expect(reports.slot("2").targeted == true)
        #expect(reports.slot("2").actionable == true)
        #expect(reports.slot("3").actionable == false)
        #expect(StepReports.none.slot("1").allowed == false)
    }

    /// While any report field in the ask is open, no row offers Report: a second link would
    /// open another field and drop the note being typed (a parent's link beside its sub-step's field).
    @Test func noReportLinkWhileAFieldIsOpen() {
        let open = StepReports(allowed: true, actionable: ["2", "2.1", "3"], reported: [], target: "2.1",
                               onReport: { _ in })
        #expect(open.slot("2").fieldOpen && open.slot("3").fieldOpen && open.slot("2.1").fieldOpen)
        #expect(!StepRow.showsReportLink(open.slot("2"), open: true, locked: false))
        #expect(!StepRow.showsReportLink(open.slot("3"), open: true, locked: false))
        #expect(StepRow.showsReportField(open.slot("2.1")))
        let idle = StepReports(allowed: true, actionable: ["2"], reported: [], target: nil, onReport: { _ in })
        #expect(!idle.slot("2").fieldOpen)
        #expect(StepRow.showsReportLink(idle.slot("2"), open: true, locked: false))
    }

    /// A parent's own Report is the last row of its card, after its sub-steps (owner pick 1:
    /// bottom right), never between its header and its sub-steps.
    @Test func aParentsReportComesAfterItsSubSteps() {
        #expect(ParentStepView.openParts(question: false) == [.body, .subSteps, .report])
        #expect(ParentStepView.openParts(question: true) == [.body, .question, .subSteps, .report])
    }

    @Test func theWarningShowsUntilTheStepIsDone() {
        let blocking = StepContent(action: "Point the domain", blocking: true)
        #expect(StepRow.warning(blocking, state: .todo, locked: false) == Flow.blockingWarning)
        #expect(StepRow.warning(blocking, state: .current, locked: false) == Flow.blockingWarning)
        #expect(StepRow.warning(blocking, state: .done, locked: false) == nil)
        #expect(StepRow.warning(blocking, state: .todo, locked: true) == nil)
        #expect(StepRow.warning(StepContent(action: "a", warning: "careful"), state: .todo, locked: false) == "careful")
        #expect(StepRow.warning(StepContent(action: "a", warning: "Do not run twice"), state: .done, locked: false) == "Do not run twice")
    }

    @Test func lockedLabels() {
        #expect(StepAccessibility.lockedLabel(level: .top(4), action: "Check the site", lockText: "Finish step 3 first")
            == "Step 4, locked: Check the site. Finish step 3 first.")
        #expect(StepAccessibility.lockedLabel(level: .verify, action: "Check", lockText: "Finish step 2 first")
            == "Verify, locked: Check. Finish step 2 first.")
        #expect(WarningBox.accessibilityText("Wait for DNS") == "Warning: Wait for DNS")
    }

    @Test func optionalLabelsAndRotorTitles() {
        #expect(StepAccessibility.optionalCaption == "Optional")
        #expect(StepAccessibility.optional("Tell us", true) == "Tell us, optional")
        #expect(StepAccessibility.optional("Tell us", false) == "Tell us")
        let nodes = DetailModel.nodes(
            steps: [Step(action: "Tell us what you think", question: Question(prompt: "Anything?"), optional: true),
                    Step(action: "Try it", substeps: [Step(action: "Note it", optional: true)])],
            verify: nil)
        #expect(Flow.flattened(nodes).map { DetailSteps<FixturePanelModel>.rotorTitle($0) }
            == ["1. Tell us what you think, optional", "2. Try it", "2a. Note it, optional"])
    }

    @Test func optionMarks() {
        #expect(OptionRows.mark(multi: false, selected: true) == DS.Symbol.optionPicked)
        #expect(OptionRows.mark(multi: false, selected: false) == nil)
        #expect(OptionRows.mark(multi: true, selected: true) == DS.Symbol.checkboxOn)
        #expect(OptionRows.mark(multi: true, selected: false) == DS.Symbol.checkboxOff)
        #expect(OptionRows.accessibilityText(index: 0, option: "Staging", sent: true) == "1, Staging, sent")
        // Step options carry no number: no key picks them.
        #expect(OptionRows.accessibilityText(index: 0, option: "Staging", sent: false, numbered: false) == "Staging")
    }

    /// The rotor leaves out locked rows and the sub-steps of a parent row that isn't open.
    @Test func theRotorSkipsLockedAndClosedRows() {
        let nodes = DetailModel.nodes(
            steps: [Step(action: "One", blocking: true),
                    Step(action: "Set up", substeps: [Step(action: "a"), Step(action: "b")]),
                    Step(action: "Three")],
            verify: nil)
        let locked = Set(Flow.lockedPaths(nodes: nodes, ticks: []))
        let rotor = DetailSteps<FixturePanelModel>.rotorNodes(nodes, ticks: [], current: "1", expanded: [], locked: locked)
        #expect(rotor.map(\.path) == ["1"])
        let open = DetailSteps<FixturePanelModel>.rotorNodes(nodes, ticks: ["1"], current: "2.1", expanded: [])
        #expect(open.map(\.path) == ["1", "2", "2.1", "2.2", "3"])
        let upcoming = DetailSteps<FixturePanelModel>.rotorNodes(nodes, ticks: [], current: "1", expanded: [])
        #expect(upcoming.map(\.path) == ["1", "2", "3"])                         // 2 is upcoming and closed
        let byHand = DetailSteps<FixturePanelModel>.rotorNodes(nodes, ticks: [], current: "1", expanded: ["2"])
        #expect(byHand.map(\.path) == ["1", "2", "2.1", "2.2", "3"])
    }

    /// One Done, no "Done sends first" caption: the unanswered count, and the warning's
    /// caption only once Done was pressed with something unsent.
    @Test func theBarCaption() {
        var snapshot = GalleryFixtures.detailSteps
        snapshot.primary = .sendAndDone
        snapshot.unsentKind = .answer
        snapshot.unansweredCaption = "1 question unanswered"
        #expect(DetailView<FixturePanelModel>.answers(snapshot).caption == "1 question unanswered")
        snapshot.doneWarning = true
        #expect(DetailView<FixturePanelModel>.answers(snapshot).caption == "You have an unsent answer")
        snapshot.unsentKind = .reply
        #expect(DetailView<FixturePanelModel>.answers(snapshot).caption == "You have an unsent reply")
        snapshot.doneWarning = false
        snapshot.primary = .done
        #expect(DetailView<FixturePanelModel>.answers(snapshot).caption == "1 question unanswered")
        snapshot.answerState = .failed(reason: "Couldn't send the answers. timed out")
        #expect(DetailView<FixturePanelModel>.answers(snapshot).failure == "Couldn't send the answers. timed out")
    }
}
