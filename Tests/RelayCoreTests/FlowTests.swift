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
