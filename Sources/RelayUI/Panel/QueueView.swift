import AppKit
import RelayCore
import SwiftUI

/// Present while the Recently closed header has keyboard focus; PanelKeys turns ← / →
/// into collapse / expand only then.
struct ClosedHeaderFocusedKey: FocusedValueKey {
    typealias Value = Bool
}

extension FocusedValues {
    var relayClosedHeaderFocused: Bool? {
        get { self[ClosedHeaderFocusedKey.self] }
        set { self[ClosedHeaderFocusedKey.self] = newValue }
    }
}

/// The queue: header, Notice, List, Undo bar and status bar. One content edge: rows have
/// zero horizontal inset and nothing in the List is a DisclosureGroup, so every text starts
/// on the gutter and every count ends at panelWidth − gutter.
struct QueueView<Model: PanelViewModel>: View {
    @ObservedObject private var model: Model
    @AppStorage("relay.closedToday.expanded") private var storedClosedExpanded = false
    @FocusState private var listFocused: Bool
    /// Rows the List has on screen (List rows appear and disappear as they scroll); Back
    /// scrolls only when the row it returns to isn't one of them.
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

    /// VO announcement when the grouping switches.
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
        let status = model.status
        VStack(spacing: 0) {
            header(queue)
            if let notice = model.notice {
                Notice(kind: notice.kind, text: notice.text, actionTitle: notice.actionTitle,
                       onAction: { model.performNoticeAction() }, onDismiss: { model.dismissNotice() })
                    .padding(.horizontal, DS.Space.gutter)
                    .padding(.top, DS.Space.inline)
                    .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
            }
            listArea(queue)
            if let undo = model.undoInfo {
                UndoBar(undo: undo, sending: model.sendingCloses > 0, onUndo: { model.undo() })
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            }
            StatusBar(symbol: status.symbol, text: status.text, onSettings: { model.shell.openSettings(nil) },
                      onActivate: StatusDetails.opensSetUp(status) ? { model.shell.setUp() } : nil) {
                StatusDetails(
                    status: status, updated: queue.updated,
                    onTryAgain: { model.refresh() },
                    onSettings: { model.shell.openSettings(.queue) },
                    onShowConfig: { NSWorkspace.shared.activateFileViewerSelecting([RelayConfig.path()]) })
            }
        }
        .animation(DS.motion(DS.Motion.reveal, reduce: reduceMotion), value: model.notice)
        .animation(DS.motion(DS.Motion.reveal, reduce: reduceMotion), value: model.undoInfo)
    }

    /// VO announcement when the project filter changes.
    static func filterAnnouncement(_ filter: String?) -> String {
        filter.map { "Showing only " + line($0) } ?? "Showing all projects"
    }

    private func header(_ queue: QueueSnapshot) -> some View {
        ListHeaderBar(
            title: queue.title, refreshing: queue.manualRefreshing, updated: queue.updated,
            grouping: Binding(get: { model.queue.grouping }, set: { model.setGrouping($0) }),
            filter: Binding(get: { model.queue.filter }, set: { model.setFilter($0) }),
            projects: queue.projects, hidden: queue.hidden,
            onRefresh: { model.refresh() },
            onHide: { model.shell.hide() },
            onDock: { model.shell.dock($0) })
            .animation(DS.motion(DS.Motion.reveal, reduce: reduceMotion), value: queue.filter)
            .onChange(of: queue.filter) { _, filter in
                AccessibilityNotification.Announcement(Self.filterAnnouncement(filter)).post()
            }
    }

    @ViewBuilder private func listArea(_ queue: QueueSnapshot) -> some View {
        if let kind = PanelStateMapping.kind(queue.content, sourceName: queue.sourceName, updated: queue.updated) {
            StateView(kind, actions: PanelStateMapping.actions(model))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            list(queue)
        }
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
                .contextMenu(forSelectionType: String.self) { ids in
                    if let id = ids.first, let row = Self.rowModel(id, in: queue) {
                        RowContextMenu(entries: QueueContextMenu.entries(for: row, filter: queue.filter)) { command in
                            perform(command, on: row)
                        }
                    }
                } primaryAction: { ids in
                    // Return or a double-click on a row.
                    if let id = ids.first { model.open(id) }
                }
                .animation(DS.motion(DS.Motion.reveal, reduce: reduceMotion), value: queue.grouping)
                .animation(DS.motion(DS.Motion.reveal, reduce: reduceMotion), value: queue.filter)
                .onAppear { if model.navigation.selectedID == nil { listFocused = true } }
                .onChange(of: activeState) { _, state in
                    if state == .key, model.navigation.selectedID == nil { listFocused = true }
                }
                .onChange(of: model.navigation.selectedID) { old, new in
                    // Back: the row you came from is centred only when it is off-screen,
                    // and the List takes focus.
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

    /// The open or closed row with this id.
    static func rowModel(_ id: String, in queue: QueueSnapshot) -> AskRowModel? {
        queue.rows[id] ?? queue.closed.first { $0.id == id }
    }

    private func perform(_ command: ContextCommand, on row: AskRowModel) {
        switch command {
        case .open: model.open(row.id)
        case .done: model.close(row.id, .done)
        case .skip: model.close(row.id, .declined)
        case .reopen: model.reopen(row.id)
        case .showOnly(let project): model.setFilter(project)
        case .showAll: model.setFilter(nil)
        case .copyLink: model.copyLink(row.id)
        case .copyResume:
            if let resume = row.resumeCommand { model.shell.copy(resume) }
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
