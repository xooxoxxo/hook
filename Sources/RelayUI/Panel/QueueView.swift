import AppKit
import RelayCore
import SwiftUI

/// The queue (design §4.3). Stub until Task 41: header title and one text row per shown ask.
struct QueueView<Model: PanelViewModel>: View {
    @ObservedObject private var model: Model

    init(model: Model) {
        _model = ObservedObject(wrappedValue: model)
    }

    var body: some View {
        let queue = model.queue
        VStack(spacing: 0) {
            PanelHeader(onDock: { model.shell.dock($0) }) {
                Text(queue.title)
                    .font(DS.Font.listTitle)
                    .monospacedDigit()
                    .accessibilityAddTraits(.isHeader)
                Spacer()
            }
            List {
                ForEach(QueueLayout.visibleOrder(queue.sections), id: \.self) { id in
                    if let row = queue.rows[id] {
                        Text(line(row.title))
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
        }
    }
}
