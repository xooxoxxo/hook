import AppKit
import RelayCore
import SwiftUI

/// True while the Recently closed header has keyboard focus (false elsewhere in the List);
/// PanelKeys turns ← / → into collapse / expand only then.
struct ClosedHeaderFocusedKey: FocusedValueKey {
    typealias Value = Bool
}

extension FocusedValues {
    var relayClosedHeaderFocused: Bool? {
        get { self[ClosedHeaderFocusedKey.self] }
        set { self[ClosedHeaderFocusedKey.self] = newValue }
    }
}

/// The queue: header, Notice, List, Undo bar and status bar. Each ask is a card (CardBackground
/// as its row background, the card content inset by `cardInsetH`/`cardInsetV`), so card text
/// starts at `cardText` and ends at panelWidth − `cardText`. Section headers and the other
/// rows keep zero horizontal inset, so their text starts on the gutter and their counts end
/// at panelWidth − gutter. Nothing in the List is a DisclosureGroup.
///
/// It doesn't observe the model: PanelRoot hands it the values it draws, and as an
/// EquatableView it re-renders only when one of them changes, so a draft keystroke, a
/// detail load or a list that changes nothing never reaches the List. The model is only
/// for actions.
struct QueueView<Model: PanelViewModel>: View, Equatable {
    private let model: Model
    private let queue: QueueSnapshot
    private let status: PanelStatus
    private let notice: PanelNotice?
    private let undo: UndoInfo?
    private let sending: Bool
    private let listSelection: String?
    private let selectedID: String?
    @AppStorage("relay.closedToday.expanded") private var storedClosedExpanded = false
    @FocusState private var listFocused: Bool
    /// The Recently closed header's focus, published by the List as `relayClosedHeaderFocused`.
    /// Never set a focused value inside a List row: on macOS each row has its own hosting
    /// view, and a focused value there leaves every row needing constraints after each layout
    /// pass, until AppKit stops the loop by raising an exception.
    @FocusState private var closedHeaderFocused: Bool
    /// Rows the List has on screen (List rows appear and disappear as they scroll); Back
    /// scrolls only when the row it returns to isn't one of them. A reference, so rows
    /// scrolling in and out never invalidate the view.
    @State private var visibleRows = VisibleRows()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.controlActiveState) private var activeState
    @Environment(\.panelGallery) private var gallery

    init(model: Model) {
        self.model = model
        queue = model.queue
        status = model.status
        notice = model.notice.flatMap { $0.showsOnQueue ? $0 : nil }
        undo = model.undoInfo
        sending = model.sendingCloses > 0
        listSelection = model.listSelection
        selectedID = model.navigation.selectedID
    }

    nonisolated static func == (a: Self, b: Self) -> Bool {
        MainActor.assumeIsolated {
            a.model === b.model && a.queue == b.queue && a.status == b.status && a.notice == b.notice
                && a.undo == b.undo && a.sending == b.sending && a.listSelection == b.listSelection
                && a.selectedID == b.selectedID
        }
    }

    static var rowInsets: EdgeInsets {
        EdgeInsets(top: DS.Space.rowInsetV, leading: DS.Space.rowInsetH,
                   bottom: DS.Space.rowInsetV, trailing: DS.Space.rowInsetH)
    }

    static var cardInsets: EdgeInsets {
        EdgeInsets(top: DS.Space.cardInsetV, leading: DS.Space.cardInsetH,
                   bottom: DS.Space.cardInsetV, trailing: DS.Space.cardInsetH)
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
        VStack(spacing: 0) {
            header(queue)
            if let notice {
                Notice(kind: notice.kind, text: notice.text, actionTitle: notice.actionTitle, help: notice.help,
                       onAction: { model.performNoticeAction() }, onDismiss: { model.dismissNotice() })
                    .padding(.horizontal, DS.Space.gutter)
                    .padding(.top, DS.Space.inline)
                    .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
            }
            listArea(queue)
            if let undo {
                UndoBar(undo: undo, sending: sending, onUndo: { model.undo() })
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
        .animation(DS.motion(DS.Motion.reveal, reduce: reduceMotion), value: notice)
        .animation(DS.motion(DS.Motion.reveal, reduce: reduceMotion), value: undo)
    }

    /// VO announcement when the project filter changes.
    static func filterAnnouncement(_ filter: String?) -> String {
        filter.map { "Showing only " + line($0) } ?? "Showing all projects"
    }

    private func header(_ queue: QueueSnapshot) -> some View {
        ListHeaderBar(
            title: queue.title, refreshing: queue.manualRefreshing, updated: queue.updated,
            // The snapshot this render holds, not `model.queue`: the header reads these often.
            grouping: Binding(get: { queue.grouping }, set: { model.setGrouping($0) }),
            filter: Binding(get: { queue.filter }, set: { model.setFilter($0) }),
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
                .cardListHighlightOff()
                .environment(\.defaultMinListRowHeight, DS.Metric.rowMinHeight)
                .focused($listFocused)
                .focusedValue(\.relayClosedHeaderFocused, closedHeaderFocused)
                .contextMenu(forSelectionType: String.self) { ids in
                    if let id = ids.first, let row = Self.rowModel(id, in: queue) {
                        RowContextMenu(entries: QueueContextMenu.entries(for: row, filter: queue.filter,
                                                                              localHost: model.localHost)) { command in
                            perform(command, on: row)
                        }
                    }
                } primaryAction: { ids in
                    // Return or a double-click on a row.
                    if let id = ids.first { model.open(id) }
                }
                .animation(DS.motion(DS.Motion.reveal, reduce: reduceMotion), value: queue.grouping)
                .animation(DS.motion(DS.Motion.reveal, reduce: reduceMotion), value: queue.filter)
                .onAppear { if selectedID == nil { listFocused = true } }
                .onChange(of: activeState) { _, state in
                    if state == .key, model.navigation.selectedID == nil { listFocused = true }
                }
                .onChange(of: selectedID) { old, new in
                    // Back: the row you came from is centred only when it is off-screen,
                    // and the List takes focus.
                    guard old != nil, new == nil else { return }
                    if let id = model.listSelection, !visibleRows.ids.contains(id) {
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
        case .resume:
            if let origin = row.origin { model.shell.resume(origin) }
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

    /// An Urgency section header already says Now or Today, so its cards show only the symbol.
    static func headerNamesUrgency(_ section: QueueSection) -> Bool {
        if case .urgency? = section.header { return true }
        return false
    }

    private func rows(_ section: QueueSection, queue: QueueSnapshot, now: Date) -> some View {
        let urgencyInHeader = Self.headerNamesUrgency(section)
        return ForEach(section.items) { item in
            if let row = queue.rows[item.id] {
                AskRow(row: row, age: RelativeAge.text(created: row.createdDate, now: now),
                       compactAge: RelativeAge.compact(created: row.createdDate, now: now),
                       urgencyInHeader: urgencyInHeader,
                       onShowOnlyProject: { model.setFilter(row.project) })
                    .equatable()
                    .simultaneousGesture(TapGesture().onEnded {
                        if ListClick.tapOpens(openDetail: model.navigation.selectedID) { model.open(row.id) }
                    })
                    .listRowInsets(Self.cardInsets)
                    .listRowBackground(CardBackground(selected: listSelection == row.id).equatable())
                    .tag(row.id)
                    .onAppear { visibleRows.ids.insert(row.id) }
                    .onDisappear { visibleRows.ids.remove(row.id) }
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
                                                    completed: row.closed?.completedDate, now: now),
                        onReopen: { model.reopen(row.id) },
                        onShowOnlyProject: { model.setFilter(row.project) })
                        .equatable()
                        .listRowInsets(Self.cardInsets)
                        .listRowBackground(CardBackground(selected: listSelection == row.id, quiet: true).equatable())
                        .tag(row.id)
                        .onAppear { visibleRows.ids.insert(row.id) }
                        .onDisappear { visibleRows.ids.remove(row.id) }
                }
            }
        } header: {
            ClosedGroupHeader(count: closed.count, expanded: closedExpanded)
                .focused($closedHeaderFocused)
        }
        .animation(DS.motion(DS.Motion.reveal, reduce: reduceMotion), value: closedExpanded.wrappedValue)
    }
}

/// The ids of the rows on screen, kept out of SwiftUI's change tracking.
final class VisibleRows {
    var ids: Set<String> = []
}
