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

    @Test func theWarningShowsUntilTheStepIsDone() {
        let blocking = StepContent(action: "Point the domain", blocking: true)
        #expect(StepRow.warning(blocking, state: .todo, locked: false) == Flow.blockingWarning)
        #expect(StepRow.warning(blocking, state: .current, locked: false) == Flow.blockingWarning)
        #expect(StepRow.warning(blocking, state: .done, locked: false) == nil)
        #expect(StepRow.warning(blocking, state: .todo, locked: true) == nil)
        #expect(StepRow.warning(StepContent(action: "a", warning: "careful"), state: .todo, locked: false) == nil)
    }

    @Test func lockedLabels() {
        #expect(StepAccessibility.lockedLabel(level: .top(4), action: "Check the site", lockText: "Finish step 3 first")
            == "Step 4, locked: Check the site. Finish step 3 first.")
        #expect(StepAccessibility.lockedLabel(level: .verify, action: "Check", lockText: "Finish step 2 first")
            == "Verify, locked: Check. Finish step 2 first.")
        #expect(WarningBox.accessibilityText("Wait for DNS") == "Warning: Wait for DNS")
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
