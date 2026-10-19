import AppKit
import RelayCore
import SwiftUI

/// One ask (design §4.4). Stub until Task 46: the title, or the not-found state when the
/// model has no snapshot for `id` (§4.7 "Not found").
struct DetailView<Model: PanelViewModel>: View {
    @ObservedObject private var model: Model
    let id: String

    init(model: Model, id: String) {
        _model = ObservedObject(wrappedValue: model)
        self.id = id
    }

    /// The ask is in Recently closed, so "Show Closed Ask" can open it.
    static func isRecentlyClosed(_ id: String, in queue: QueueSnapshot) -> Bool {
        queue.closed.contains { $0.id == id }
    }

    var body: some View {
        if let snapshot = model.detail(id) {
            Text(line(snapshot.row.title))
                .font(DS.Font.askTitle)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            notFound
        }
    }

    private var notFound: some View {
        VStack(spacing: 0) {
            PanelHeader(onDock: { model.shell.dock($0) }) {
                IconButton(DS.Symbol.back, label: "Back to the queue", help: "Back to the queue (Esc)") { model.back() }
                Spacer()
                // Esc goes back in detail (§4.12), so Hide names ⌘W (Task 9 ruling, N8).
                IconButton(DS.Symbol.hide, label: "Hide Relay", help: DetailHeaderBar.hideHelp) { model.shell.hide() }
            }
            StateView(
                .notFound(canShowClosed: Self.isRecentlyClosed(id, in: model.queue)),
                actions: StateActions(
                    settings: { model.shell.openSettings(.queue) },
                    tryAgain: { model.refresh() },
                    setUp: { model.shell.setUp() },
                    showAll: { model.setFilter(nil) },
                    backToQueue: { model.back() },
                    showClosed: { model.open(id) }))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
