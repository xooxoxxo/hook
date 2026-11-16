import Foundation
import RelayCore
import Testing
@testable import RelayUI
@testable import RelayUIMac

/// The detail's divider above added steps: the runs it cuts the steps into, and the scroll to
/// it once per marker.
@MainActor @Suite struct AppendDividerTests {
    private func node(_ number: Int) -> DetailModel.Node {
        DetailModel.Node(path: "\(number)", label: "\(number)", kind: .step, number: number,
                         content: StepContent(action: "Step \(number)"), fingerprint: "", stepID: "s\(number)")
    }

    @Test func segmentsCutAtEachDivider() {
        let entries: [StepEntry] = [.node(node(1)), .node(node(2)), .appendMarker(rev: 2, title: "T2", note: "N2"),
                                    .node(node(3)), .appendMarker(rev: 3, title: "T3", note: "N3"), .node(node(4))]
        let segments = DetailSteps<Store>.segments(entries)
        #expect(segments.map(\.id) == [0, 2, 3])
        #expect(segments.map { $0.nodes.map(\.number) } == [[1, 2], [3], [4]])
        #expect(segments.map(\.divider) == [nil, .init(title: "T2", note: "N2"), .init(title: "T3", note: "N3")])
        #expect(DetailSteps<Store>.segments([.node(node(1))]).map(\.id) == [0])
        #expect(DetailSteps<Store>.dividerID(2) == "append-2")
    }

    @Test func scrollsOncePerMarker() {
        let scroll = DetailView<Store>.newStepsScroll
        #expect(scroll([2], nil).map { [$0.target, $0.newest] } == [2, 2])
        #expect(scroll([2], 2) == nil)
        #expect(scroll([2, 3], 2).map { [$0.target, $0.newest] } == [3, 3])
        #expect(scroll([], nil) == nil)
        // Several unseen appends: the oldest new divider, so the first new step is in view.
        #expect(scroll([2, 3, 4], nil).map { [$0.target, $0.newest] } == [2, 4])
        #expect(scroll([2, 3, 4, 5], 3).map { [$0.target, $0.newest] } == [4, 5])
    }
}

/// While Done waits for the session's next steps: the bar's line, its "?", Done off with the
/// same words, Skip on.
@MainActor @Suite struct WaitingForStepsBarTests {
    private func waiting() -> DetailSnapshot {
        var snapshot = GalleryFixtures.detailSteps
        snapshot.stepWait = StepWait(stepID: "s2", path: "2", until: Date(timeIntervalSince1970: 1_800_000_000))
        snapshot.doneEnabled = false
        snapshot.discardEnabled = false
        return snapshot
    }

    @Test func theBarSaysWaiting() {
        let answers = DetailView<Store>.answers(waiting())
        #expect(answers.caption == "Waiting for next steps…")
        #expect(answers.help == "The session said more steps follow your answer. "
            + "Done comes back when they arrive, or after 10 minutes.")
        let gate = DetailView<Store>.gate(waiting())
        #expect(!gate.doneEnabled)
        #expect(gate.doneHelp == "Waiting for next steps…")
        let buttons = ActionBar.buttons(DetailView<Store>.actionMode(waiting()), doneEnabled: gate.doneEnabled,
                                        discardEnabled: gate.discardEnabled, doneHelp: gate.doneHelp)
        #expect(buttons.map(\.enabled) == [true, false])
        #expect(buttons.map(\.role) == [.skip, .primary])
        // Without a wait, the bar keeps its usual caption and no "?".
        #expect(DetailView<Store>.answers(GalleryFixtures.detailSteps).help == nil)
    }
}
