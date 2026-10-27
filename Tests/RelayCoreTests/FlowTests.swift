import Foundation
import Testing
@testable import RelayCore

/// 1, 2 (2.1, 2.2, 2.3), 3, verify: leaves 1, 2.1, 2.2, 2.3, 3, verify.
private let nodes = DetailModel.nodes(
    steps: [
        Step(action: "One"),
        Step(action: "Two", substeps: [Step(action: "a"), Step(action: "b"), Step(action: "c")]),
        Step(action: "Three"),
    ],
    verify: Step(action: "Check"))

@Suite struct FlowTests {
    @Test func leavesAndRotorOrder() {
        #expect(Flow.leaves(of: nodes).map(\.path) == ["1", "2.1", "2.2", "2.3", "3", "verify"])
        #expect(Flow.flattened(nodes).map(\.path) == ["1", "2", "2.1", "2.2", "2.3", "3", "verify"])
    }

    @Test func currentIsTheFirstUntickedLeaf() {
        #expect(Flow.currentStep(ticks: [], nodes: nodes) == "1")
        #expect(Flow.currentStep(ticks: ["1"], nodes: nodes) == "2.1")
        #expect(Flow.currentStep(ticks: ["1", "2.1", "2.3"], nodes: nodes) == "2.2")
        #expect(Flow.currentStep(ticks: ["2"], nodes: nodes) == "1")
        #expect(Flow.currentStep(ticks: ["1", "2.1", "2.2", "2.3", "3"], nodes: nodes) == "verify")
        #expect(Flow.currentStep(ticks: ["1", "2.1", "2.2", "2.3", "3", "verify"], nodes: nodes) == nil)
        #expect(Flow.currentStep(ticks: [], nodes: []) == nil)
    }

    @Test func progressCountsLeaves() {
        #expect(Flow.progress(ticks: [], nodes: nodes) == StepProgress(done: 0, total: 6))
        #expect(Flow.progress(ticks: ["1", "2.2", "2", "gone"], nodes: nodes) == StepProgress(done: 2, total: 6))
        #expect(Flow.parentProgress(nodes[1], ticks: ["2.1", "2.3", "1"]) == StepProgress(done: 2, total: 3))
    }

    @Test func states() {
        let leaves = Flow.leaves(of: nodes)
        let ticks: Set<String> = ["1"]
        let current = Flow.currentStep(ticks: ticks, nodes: nodes)
        #expect(leaves.prefix(3).map { Flow.state(of: $0, ticks: ticks, current: current) } == [.done, .current, .todo])
    }

    @Test func toggleLeafAndParent() {
        #expect(Flow.toggle(nodes[0], ticks: []) == ["1"])
        #expect(Flow.toggle(nodes[0], ticks: ["1"]) == [])
        #expect(Flow.toggle(nodes[1], ticks: ["2.2"]) == ["2.1", "2.2", "2.3"])
        #expect(Flow.toggle(nodes[1], ticks: ["2.1", "2.2", "2.3", "1"]) == ["1"])
        #expect(Flow.toggle(nodes[1].children[1], ticks: ["2.2"]) == [])
    }

    @Test func tickCurrentWalksLeavesAndNeverTicksAParent() {
        var ticks: Set<String> = []
        var walked: [String] = []
        while let path = Flow.tickCurrent(ticks: ticks, nodes: nodes).path {
            ticks = Flow.tickCurrent(ticks: ticks, nodes: nodes).ticks
            walked.append(path)
        }
        #expect(walked == ["1", "2.1", "2.2", "2.3", "3", "verify"])
        #expect(!ticks.contains("2"))
        #expect(Flow.tickCurrent(ticks: ticks, nodes: nodes).path == nil)
    }

    @Test func untickLastUsesHistoryThenOrder() {
        let ticks: Set<String> = ["1", "2.1", "2.2"]
        let fromHistory = Flow.untickLast(ticks: ticks, history: ["2.2", "1", "3"], nodes: nodes)
        #expect(fromHistory.path == "1")
        #expect(fromHistory.ticks == ["2.1", "2.2"])
        let fromOrder = Flow.untickLast(ticks: ticks, history: ["3"], nodes: nodes)
        #expect(fromOrder.path == "2.2")
        #expect(fromOrder.ticks == ["1", "2.1"])
        #expect(Flow.untickLast(ticks: [], history: [], nodes: nodes).path == nil)
        #expect(Flow.untickLast(ticks: ["2"], history: ["2"], nodes: nodes).path == nil)
    }
}

@Suite struct NextAskTests {
    @Test func middleGoesDown() { #expect(Flow.nextAsk(after: "b", in: ["a", "b", "c"]) == "c") }
    @Test func firstGoesDown() { #expect(Flow.nextAsk(after: "a", in: ["a", "b", "c"]) == "b") }
    @Test func lastGoesUp() { #expect(Flow.nextAsk(after: "c", in: ["a", "b", "c"]) == "b") }
    @Test func singleHasNone() { #expect(Flow.nextAsk(after: "a", in: ["a"]) == nil) }
    @Test func emptyHasNone() { #expect(Flow.nextAsk(after: "a", in: []) == nil) }
    @Test func outsideTheFilterTakesTheFirst() { #expect(Flow.nextAsk(after: "x", in: ["a", "b"]) == "a") }
    @Test func outsideTheFilterWithNothingShownHasNone() { #expect(Flow.nextAsk(after: "x", in: []) == nil) }

    /// Closing every ask in turn: each close opens the next until none is left.
    @Test func theListDrainsInOrder() {
        var order = ["a", "b", "c"]
        var opened: [String] = []
        var current: String? = "a"
        while let id = current {
            current = Flow.nextAsk(after: id, in: order)
            order.removeAll { $0 == id }
            if let next = current { opened.append(next) }
        }
        #expect(opened == ["b", "c"])
    }
}

@Suite struct PrimaryActionTests {
    @Test func doneByDefault() {
        #expect(Flow.primaryAction(draft: nil, choice: nil, sent: nil) == .done)
        #expect(Flow.primaryAction(draft: " \n", choice: nil, sent: nil) == .done)
    }

    @Test func aDraftMakesItSendAndDone() {
        #expect(Flow.primaryAction(draft: "C07", choice: nil, sent: nil) == .sendAndDone)
    }

    @Test func aPickedUnsentChoiceMakesItSendAndDone() {
        #expect(Flow.primaryAction(draft: nil, choice: 1, sent: nil) == .sendAndDone)
        #expect(Flow.primaryAction(draft: nil, choice: 1, sent: 0) == .sendAndDone)
        #expect(Flow.primaryAction(draft: nil, choice: 1, sent: 1) == .done)
        #expect(Flow.primaryAction(draft: nil, choice: nil, sent: 1) == .done)
    }
}

@Suite struct ScrollAnchorTests {
    private let order = ["1", "2", "3", "4", "verify"]

    @Test func topVisibleIsTheFirstVisibleInOrder() {
        #expect(Flow.topVisible(visible: ["3", "2"], order: order) == "2")
        #expect(Flow.topVisible(visible: ["verify"], order: order) == "verify")
    }

    @Test func nothingVisibleOrUnknownPathsGiveNoAnchor() {
        #expect(Flow.topVisible(visible: [], order: order) == nil)
        #expect(Flow.topVisible(visible: ["2.1", "x"], order: order) == nil)
    }

    @Test func visibleIsEveryFrameOverlappingTheBand() {
        let frames: [String: CGRect] = [
            "1": CGRect(x: 0, y: -200, width: 348, height: 150),   // scrolled away above
            "2": CGRect(x: 0, y: 20, width: 348, height: 80),      // under the 44 pt header, bottom still visible
            "3": CGRect(x: 0, y: 300, width: 348, height: 80),
            "4": CGRect(x: 0, y: 900, width: 348, height: 80),     // below the action bar
        ]
        #expect(Flow.visible(frames: frames, top: 44, bottom: 764) == ["2", "3"])
        #expect(Flow.topVisible(visible: Flow.visible(frames: frames, top: 44, bottom: 764), order: order) == "2")
    }

    @Test func scrollOnlyWhenTheNewCurrentStartsBelowTheVisibleArea() {
        #expect(Flow.needsScroll(nodeTop: 800, visibleBottom: 764))
        #expect(Flow.needsScroll(nodeTop: 764, visibleBottom: 764))
        #expect(!Flow.needsScroll(nodeTop: 500, visibleBottom: 764))
        #expect(!Flow.needsScroll(nodeTop: -40, visibleBottom: 764))
    }

    @Test func visibleBottomUsesTheMeasuredBarHeight() {
        // Not measured yet: the designed 56 pt, the old behaviour.
        #expect(Flow.visibleBottom(viewportHeight: 820, barHeight: 0, fallback: 56) == 764)
        // Divider + 56.
        #expect(Flow.visibleBottom(viewportHeight: 820, barHeight: 57, fallback: 56) == 763)
        // The unanswered caption wrapped onto its own line, or the undo bar shows.
        #expect(Flow.visibleBottom(viewportHeight: 820, barHeight: 92, fallback: 56) == 728)
    }

    @Test func aStepBehindATallerBarNeedsScroll() {
        let top: CGFloat = 740
        let unmeasured = Flow.visibleBottom(viewportHeight: 820, barHeight: 0, fallback: 56)
        let measured = Flow.visibleBottom(viewportHeight: 820, barHeight: 92, fallback: 56)
        #expect(!Flow.needsScroll(nodeTop: top, visibleBottom: unmeasured))
        #expect(Flow.needsScroll(nodeTop: top, visibleBottom: measured))
        let frames = ["1": CGRect(x: 0, y: top, width: 348, height: 60)]
        #expect(Flow.visible(frames: frames, top: 44, bottom: measured).isEmpty)
    }

    @Test func unscrolledAskAnchorsOnTheTitleNotStepOne() {
        let frames: [String: CGRect] = [
            "title": CGRect(x: 0, y: 60, width: 348, height: 160),
            "1": CGRect(x: 0, y: 240, width: 348, height: 80),
        ]
        #expect(Flow.topVisible(visible: Flow.visible(frames: frames, top: 44, bottom: 764), order: ["title"] + order) == "title")
    }
}

// MARK: Blocking steps

private func answer(_ path: String) -> Answer { Answer(step: path, picked: ["EU"], at: "2026-10-27T09:00:00+00:00", seq: 1) }

@Suite struct FlowLockTests {
    /// 1, 2 blocking, 3, verify.
    private let simple = DetailModel.nodes(
        steps: [Step(action: "One"), Step(action: "Revoke", blocking: true), Step(action: "Three")],
        verify: Step(action: "Check"))

    @Test func nothingIsLockedWithoutABlockingStep() {
        #expect(Flow.lockedPaths(nodes: nodes, ticks: []) == [])
        #expect(Flow.firstOpenBlock(nodes: nodes, ticks: []) == nil)
    }

    @Test func aBlockingStepLocksEverythingAfterItUntilTicked() {
        #expect(Flow.lockedPaths(nodes: simple, ticks: []) == ["3", "verify"])
        #expect(Flow.lockedPaths(nodes: simple, ticks: ["1"]) == ["3", "verify"])
        #expect(Flow.lockedPaths(nodes: simple, ticks: ["2"]) == [])
        #expect(Flow.firstOpenBlock(nodes: simple, ticks: [])?.path == "2")
    }

    @Test func aWarningAloneLocksNothing() {
        let warned = DetailModel.nodes(steps: [Step(action: "a", warning: "careful"), Step(action: "b")], verify: nil)
        #expect(Flow.lockedPaths(nodes: warned, ticks: []) == [])
    }

    @Test func theFirstUnfinishedBlockWins() {
        let two = DetailModel.nodes(
            steps: [Step(action: "a", blocking: true), Step(action: "b", blocking: true), Step(action: "c")], verify: nil)
        #expect(Flow.lockedPaths(nodes: two, ticks: []) == ["2", "3"])
        #expect(Flow.lockedPaths(nodes: two, ticks: ["1"]) == ["3"])
        #expect(Flow.lockedPaths(nodes: two, ticks: ["2"]) == ["2", "3"])   // ticking past a lock doesn't open it
        #expect(Flow.lockedPaths(nodes: two, ticks: ["1", "2"]) == [])
    }

    @Test func aBlockingQuestionNeedsItsAnswer() {
        let asked = DetailModel.nodes(
            steps: [Step(action: "Region", question: Question(prompt: "Which?", choices: ["EU", "US"]), blocking: true),
                    Step(action: "Deploy")],
            verify: nil, answers: [:])
        #expect(Flow.lockedPaths(nodes: asked, ticks: ["1"]) == ["2"])      // a tick doesn't answer it
        let answered = DetailModel.nodes(
            steps: [Step(action: "Region", question: Question(prompt: "Which?", choices: ["EU", "US"]), blocking: true),
                    Step(action: "Deploy")],
            verify: nil, answers: ["1": answer("1")])
        #expect(Flow.lockedPaths(nodes: answered, ticks: []) == [])
    }

    @Test func aBlockingParentKeepsItsSubstepsOpenAndNeedsThemAllDone() {
        let parent = DetailModel.nodes(
            steps: [Step(action: "Set up", substeps: [Step(action: "a"), Step(action: "b")], blocking: true),
                    Step(action: "Deploy")],
            verify: Step(action: "Check"))
        #expect(Flow.lockedPaths(nodes: parent, ticks: []) == ["2", "verify"])
        #expect(Flow.lockedPaths(nodes: parent, ticks: ["1.1"]) == ["2", "verify"])
        #expect(Flow.lockedPaths(nodes: parent, ticks: ["1.1", "1.2"]) == [])
        #expect(Flow.lockedPaths(nodes: parent, ticks: ["1"]) == ["2", "verify"])  // a parent isn't ticked as a unit
    }

    @Test func aBlockingParentWithAQuestionNeedsItsOwnAnswerToo() {
        let steps = [Step(action: "Set up", substeps: [Step(action: "a")],
                          question: Question(prompt: "Which?", choices: ["EU", "US"]), blocking: true),
                     Step(action: "Deploy")]
        let open = DetailModel.nodes(steps: steps, verify: nil)
        #expect(Flow.lockedPaths(nodes: open, ticks: ["1.1"]) == ["2"])
        let answered = DetailModel.nodes(steps: steps, verify: nil, answers: ["1": answer("1")])
        #expect(Flow.lockedPaths(nodes: answered, ticks: []) == ["2"])
        #expect(Flow.lockedPaths(nodes: answered, ticks: ["1.1"]) == [])
    }

    @Test func aBlockingSubstepLocksItsLaterSiblingsAndWhatFollows() {
        let sub = DetailModel.nodes(
            steps: [Step(action: "Set up", substeps: [Step(action: "a"), Step(action: "b", blocking: true), Step(action: "c")]),
                    Step(action: "Deploy")],
            verify: Step(action: "Check"))
        #expect(Flow.lockedPaths(nodes: sub, ticks: []) == ["1.3", "2", "verify"])
        #expect(Flow.lockedPaths(nodes: sub, ticks: ["1.2"]) == [])
    }

    @Test func theLockLineNamesTheBlockingStep() {
        #expect(Flow.lockText(nodes: simple, ticks: []) == "Finish step 2 first")
        #expect(Flow.lockText(nodes: simple, ticks: ["2"]) == nil)
        let sub = DetailModel.nodes(
            steps: [Step(action: "Set up", substeps: [Step(action: "a", blocking: true), Step(action: "b")])], verify: nil)
        #expect(Flow.lockText(nodes: sub, ticks: []) == "Finish step 1a first")
    }

    @Test func theWarningFallsBackToTheDefaultLine() {
        let nodes = DetailModel.nodes(
            steps: [Step(action: "a", blocking: true), Step(action: "b", blocking: true, warning: "Wait for DNS"),
                    Step(action: "c", warning: "careful")],
            verify: nil)
        #expect(Flow.warningText(nodes[0]) == Flow.blockingWarning)
        #expect(Flow.warningText(nodes[1]) == "Wait for DNS")
        #expect(Flow.warningText(nodes[2]) == nil)        // a warning without blocking draws no box
    }

    @Test func aLockedStepIsNeverToggled() {
        let locked = Set(Flow.lockedPaths(nodes: simple, ticks: []))
        #expect(Flow.toggle(simple[2], ticks: [], locked: locked) == [])
        #expect(Flow.toggle(simple[1], ticks: [], locked: locked) == ["2"])
        let sub = DetailModel.nodes(
            steps: [Step(action: "Set up", substeps: [Step(action: "a", blocking: true), Step(action: "b")])], verify: nil)
        let subLocked = Set(Flow.lockedPaths(nodes: sub, ticks: []))
        // The parent ticks only its open sub-steps; the one after the blocking sub-step stays.
        #expect(Flow.toggle(sub[0], ticks: [], locked: subLocked) == ["1.1"])
    }

    @Test func tickCurrentTicksTheBlockingStepAndUnlocksWhatFollows() {
        let first = Flow.tickCurrent(ticks: ["1"], nodes: simple)
        #expect(first.path == "2")
        #expect(Flow.lockedPaths(nodes: simple, ticks: first.ticks) == [])
        #expect(Flow.currentStep(ticks: first.ticks, nodes: simple) == "3")
    }
}
