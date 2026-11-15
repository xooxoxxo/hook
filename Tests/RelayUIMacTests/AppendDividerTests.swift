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
        #expect(DetailView<Store>.scrollsToNewSteps(2, scrolled: nil))
        #expect(!DetailView<Store>.scrollsToNewSteps(2, scrolled: 2))
        #expect(DetailView<Store>.scrollsToNewSteps(3, scrolled: 2))
        #expect(!DetailView<Store>.scrollsToNewSteps(nil, scrolled: nil))
    }
}
