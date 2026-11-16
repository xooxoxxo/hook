import AppKit
import RelayCore
import SwiftUI
import Testing
@testable import RelayUI
@testable import RelayUIMac

/// The queue must not use AppKit's source-list hover accessories. In 0.15.4 they
/// could keep invalidating header constraints as undo expired and focus returned,
/// until AppKit terminated the app.
@Suite(.serialized) @MainActor struct QueueUndoLayoutTests {
    @Test(arguments: [false, true])
    func closingAndExpiringUndoKeepsLayoutStable(closedExpanded: Bool) async throws {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        defaults.defaults.set(closedExpanded, forKey: "relay.closedToday.expanded")
        let clock = TestClock()
        clock.now = Date()
        let open = (0..<35).map { index in
            item("layout-\(index)", project: "Project \(index % 4)",
                 created: Timestamp.string(clock.now.addingTimeInterval(-Double(index + 1) * 60)))
        }
        let source = FakeQueueSource(items: open)
        await source.setClosed([closed(item("already-closed", created: Timestamp.string(clock.now)))])
        let store = Store(defaults: defaults.defaults, now: { clock.now })
        await start(store, source)
        store.afterClose = .queue
        store.setGrouping(.project)
        let panel = makePanel(store: store, defaults: defaults.defaults)
        defer {
            panel.orderOut(nil)
            panel.contentView = nil
            store.swap(to: nil, identity: localIdentity, pollSeconds: 3600)
        }
        let content = try #require(panel.contentView)
        let table = try #require(findTable(in: content))
        try checkStyle(table)
        for index in 0..<3 {
            let id = open[index].id
            store.open(id)
            #expect(await eventually { store.detail(id)?.load == .loaded })
            store.close(id, .done)
            #expect(store.navigation.selectedID == nil)
            #expect(store.undoInfo != nil)
            panel.makeFirstResponder(table)
            await settle(panel)
            try checkStyle(table)

            clock.advance(11)
            store.sendDue()
            #expect(await eventually { await source.count("resolve \(id) done") == 1 })
            await store.refresh()
            panel.makeFirstResponder(nil)
            panel.makeFirstResponder(table)
            await settle(panel)
            #expect(store.undoInfo == nil)
            #expect(store.queue.closed.contains { $0.id == id })
            try checkStyle(table)
        }
    }

    private func checkStyle(_ table: NSTableView) throws {
        #expect(table.numberOfRows > 0)
        // Guard the actual AppKit behavior, including a future SwiftUI style remapping.
        // Stop before entering another display cycle if the crashing source-list style returns.
        try #require(table.style != .sourceList)
    }

    private func findTable(in view: NSView) -> NSTableView? {
        if let table = view as? NSTableView { return table }
        return view.subviews.lazy.compactMap { findTable(in: $0) }.first
    }

    private func settle(_ panel: NSPanel) async {
        // Let animation frames and other main-actor tests run during the wait.
        try? await Task.sleep(for: .milliseconds(400))
        panel.layoutIfNeeded()
        func dirty(_ view: NSView) -> [String] {
            let here = view.needsLayout || view.needsUpdateConstraints ? ["\(type(of: view))"] : []
            return here + view.subviews.flatMap(dirty)
        }
        let root = panel.contentView!.superview ?? panel.contentView!
        #expect(dirty(root).isEmpty)
    }

    private func makePanel(store: Store, defaults: UserDefaults) -> NSPanel {
        let host = NSHostingView(rootView: PanelRoot(model: store).defaultAppStorage(defaults))
        host.sizingOptions = []
        host.safeAreaRegions = []
        host.translatesAutoresizingMaskIntoConstraints = false
        let background = NSVisualEffectView()
        background.material = .sidebar
        background.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            host.topAnchor.constraint(equalTo: background.topAnchor),
            host.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])
        let panel = NSPanel(contentRect: NSRect(x: -20000, y: -20000, width: 380, height: 1125),
                            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
                            backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.contentView = background
        panel.layoutIfNeeded()
        return panel
    }
}
