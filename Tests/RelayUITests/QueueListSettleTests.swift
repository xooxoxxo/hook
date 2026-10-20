import AppKit
import RelayCore
import SwiftUI
import Testing
@testable import RelayUI

/// The queue in a window built like the side panel (a borderless non-activating panel, the
/// sidebar material, the hosting view pinned to it with constraints and no sizing options)
/// settles after one layout pass. A short queue with a Recently closed section puts the
/// section header on screen; a focused value set inside that List row once left every row's
/// hosting view needing constraints again after each pass, and AppKit ended the loop by
/// raising an exception a few seconds after launch.
@Suite @MainActor struct QueueListSettleTests {
    private func panel(closedExpanded: Bool) -> NSPanel {
        let queue = GalleryFixtures.queue(grouping: .project, filter: nil, closedExpanded: closedExpanded)
        let status = PanelStatus.make(StatusInputs(sourceKey: "mailbox:mailbox.example:8790#personal",
                                                   reachable: true, loadedOnce: true))
        let model = FixturePanelModel(queue: queue, status: status)
        let overrides = PanelGalleryOverrides(now: GalleryFixtures.now, closedExpanded: closedExpanded)
        let host = NSHostingView(rootView: PanelRoot(model: model).environment(\.panelGallery, overrides))
        host.sizingOptions = []
        host.safeAreaRegions = []
        host.translatesAutoresizingMaskIntoConstraints = false
        let background = NSVisualEffectView()
        background.material = .sidebar
        background.blendingMode = .behindWindow
        background.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            host.topAnchor.constraint(equalTo: background.topAnchor),
            host.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])
        let panel = NSPanel(contentRect: NSRect(x: -20000, y: -20000, width: DS.Metric.panelWidth, height: 900),
                            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
                            backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.contentView = background
        return panel
    }

    /// Views under `view` that still need constraints or layout.
    private static func unsettled(_ view: NSView) -> [String] {
        let here = view.needsUpdateConstraints || view.needsLayout ? ["\(type(of: view))"] : []
        return here + view.subviews.flatMap(unsettled)
    }

    @Test(arguments: [false, true]) func queueWithRecentlyClosedSettles(closedExpanded: Bool) {
        let panel = panel(closedExpanded: closedExpanded)
        defer { panel.contentView = nil }
        let frame = panel.contentView?.superview ?? panel.contentView!
        panel.layoutIfNeeded()
        let dirty = Self.unsettled(frame)
        #expect(dirty.isEmpty, "still dirty after a layout pass: \(dirty)")
        // A view that never settles makes the display cycle below raise, so stop here.
        guard dirty.isEmpty else { return }
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        panel.layoutIfNeeded()
        #expect(Self.unsettled(frame).isEmpty)
    }
}
