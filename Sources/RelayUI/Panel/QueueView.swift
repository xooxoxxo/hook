import AppKit
import RelayCore
import SwiftUI

/// Present while the Recently closed header has keyboard focus; PanelKeys turns ← / →
/// into collapse / expand only then (design §4.12).
struct ClosedHeaderFocusedKey: FocusedValueKey {
    typealias Value = Bool
}

extension FocusedValues {
    var relayClosedHeaderFocused: Bool? {
        get { self[ClosedHeaderFocusedKey.self] }
        set { self[ClosedHeaderFocusedKey.self] = newValue }
    }
}

/// The queue (design §4.3): header, List, then (Task 43) bars. One content edge: rows have
/// zero horizontal inset and nothing in the List is a DisclosureGroup, so every text starts
/// on the gutter and every count ends at panelWidth − gutter.
struct QueueView<Model: PanelViewModel>: View {
    @ObservedObject private var model: Model
    @AppStorage("relay.closedToday.expanded") private var storedClosedExpanded = false
    @FocusState private var listFocused: Bool
    /// Rows the List has on screen (List rows appear and disappear as they scroll); Back
    /// scrolls only when the row it returns to isn't one of them (design §4.6).
    @State private var visibleRows: Set<String> = []
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.controlActiveState) private var activeState
    @Environment(\.panelGallery) private var gallery

    init(model: Model) {
        _model = ObservedObject(wrappedValue: model)
    }

    static var rowInsets: EdgeInsets {
        EdgeInsets(top: DS.Space.rowInsetV, leading: DS.Space.rowInsetH,
                   bottom: DS.Space.rowInsetV, trailing: DS.Space.rowInsetH)
    }

    /// VO announcement when the grouping switches (design §4.3).
    static func groupingAnnouncement(_ grouping: QueueGrouping) -> String {
        grouping == .project ? "Grouped by project" : "Grouped by urgency"
    }

    /// The urgency word, or the raw project (SectionHeader sanitizes it; "" shows "No project").
    static func headerName(_ header: QueueSection.Header) -> String {
        switch header {
        case .urgency(let urgency): urgency.word
        case .project(let project): project
        }
    }

    private var closedExpanded: Binding<Bool> {
        Binding(get: { gallery.closedExpanded ?? storedClosedExpanded },
                set: { storedClosedExpanded = $0 })
    }

    /// Only the List calls this setter (a click or an arrow key); a left click also opens.
    private var selection: Binding<String?> {
        Binding(get: { model.listSelection }, set: { id in
            model.listSelection = id
            if let id, ListClick.opensOnSelection(NSApp.currentEvent?.type) { model.open(id) }
        })
    }

    var body: some View {
        let queue = model.queue
        VStack(spacing: 0) {
            header(queue)
            listArea(queue)
        }
    }

    private func header(_ queue: QueueSnapshot) -> some View {
        PanelHeader(onDock: { model.shell.dock($0) }) {
            Text(queue.title)
                .font(DS.Font.listTitle)
                .monospacedDigit()
                .accessibilityAddTraits(.isHeader)
                .alignmentProbe(.gutterText)
            Spacer()
        }
    }

    @ViewBuilder private func listArea(_ queue: QueueSnapshot) -> some View {
        list(queue)
    }

    private func list(_ queue: QueueSnapshot) -> some View {
        TimelineView(.everyMinute) { context in
            let now = gallery.now ?? context.date
            ScrollViewReader { proxy in
                List(selection: selection) {
                    ForEach(queue.sections) { section in
                        sectionView(section, queue: queue, now: now)
                    }
                    if queue.sections.isEmpty && !queue.closed.isEmpty {
                        EmptyListLine(project: queue.filter, onShowAll: { model.setFilter(nil) })
                            .listRowInsets(Self.rowInsets)
                    }
                    if !queue.closed.isEmpty {
                        closedSection(queue.closed, now: now)
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
                .environment(\.defaultMinListRowHeight, DS.Metric.rowMinHeight)
                .focused($listFocused)
                .animation(DS.motion(DS.Motion.reveal, reduce: reduceMotion), value: queue.grouping)
                .animation(DS.motion(DS.Motion.reveal, reduce: reduceMotion), value: queue.filter)
                .onAppear { listFocused = true }
                .onChange(of: activeState) { _, state in
                    if state == .key { listFocused = true }
                }
                .onChange(of: model.navigation.selectedID) { old, new in
                    // Back: the row you came from is centred only when it is off-screen
                    // (design §4.6), and the List takes focus.
                    guard old != nil, new == nil else { return }
                    if let id = model.listSelection, !visibleRows.contains(id) {
                        proxy.scrollTo(id, anchor: .center)
                    }
                    listFocused = true
                }
                .onChange(of: queue.grouping) { _, grouping in
                    AccessibilityNotification.Announcement(Self.groupingAnnouncement(grouping)).post()
                    if let id = model.listSelection { proxy.scrollTo(id) }
                }
            }
        }
    }

    @ViewBuilder private func sectionView(_ section: QueueSection, queue: QueueSnapshot, now: Date) -> some View {
        if let header = section.header {
            Section {
                rows(section, queue: queue, now: now)
            } header: {
                SectionHeader(name: Self.headerName(header), count: section.items.count)
            }
        } else {
            Section {
                rows(section, queue: queue, now: now)
            }
        }
    }

    private func rows(_ section: QueueSection, queue: QueueSnapshot, now: Date) -> some View {
        ForEach(section.items) { item in
            if let row = queue.rows[item.id] {
                AskRow(row: row, age: RelativeAge.text(created: row.created, now: now), grouping: queue.grouping,
                       selected: model.listSelection == row.id,
                       onShowOnlyProject: { model.setFilter(row.project) })
                    .simultaneousGesture(TapGesture().onEnded {
                        if ListClick.tapOpens(openDetail: model.navigation.selectedID) { model.open(row.id) }
                    })
                    .listRowInsets(Self.rowInsets)
                    .tag(row.id)
                    .onAppear { visibleRows.insert(row.id) }
                    .onDisappear { visibleRows.remove(row.id) }
            }
        }
    }

    /// Recently closed: the header row is the disclosure; the closed rows are the section's
    /// own rows (never DisclosureGroup children), so they share the open rows' text edge.
    private func closedSection(_ closed: [AskRowModel], now: Date) -> some View {
        Section {
            if closedExpanded.wrappedValue {
                ForEach(closed) { row in
                    ClosedAskRow(
                        row: row,
                        closedLine: ClosedLine.text(status: row.closed?.status ?? "", closedBy: row.closed?.closedBy,
                                                    completedAt: row.closed?.completedAt, now: now),
                        onReopen: { model.reopen(row.id) },
                        onShowOnlyProject: { model.setFilter(row.project) })
                        .listRowInsets(Self.rowInsets)
                        .tag(row.id)
                        .onAppear { visibleRows.insert(row.id) }
                        .onDisappear { visibleRows.remove(row.id) }
                }
            }
        } header: {
            ClosedGroupHeader(count: closed.count, expanded: closedExpanded)
                .focusedValue(\.relayClosedHeaderFocused, true)
        }
        .animation(DS.motion(DS.Motion.reveal, reduce: reduceMotion), value: closedExpanded.wrappedValue)
    }
}
