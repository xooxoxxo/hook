import Foundation
import RelayCore

/// A PanelViewModel over fixed snapshots, for the gallery. Actions don't change the
/// snapshots (each scene is one state); view state (selection, drafts…) is kept.
public final class FixturePanelModel: PanelViewModel {
    @Published public var queue: QueueSnapshot
    @Published public var navigation: PanelNavigation
    @Published public var drafts: [String: String] = [:]
    @Published public var pendingChoice: [String: Int] = [:]
    @Published public var expandedDone: [String: Set<String>] = [:]
    @Published public var detailAnchor: [String: String] = [:]
    @Published public var notice: PanelNotice?
    @Published public var undoInfo: UndoInfo?
    @Published public var status: PanelStatus
    @Published public var sendingCloses = 0
    public var shell = PanelShellActions.none
    private let details: [String: DetailSnapshot]

    public init(queue: QueueSnapshot, details: [String: DetailSnapshot] = [:], navigation: PanelNavigation = .init(),
                notice: PanelNotice? = nil, undo: UndoInfo? = nil, status: PanelStatus) {
        self.queue = queue
        self.details = details
        self.navigation = navigation
        self.notice = notice
        undoInfo = undo
        self.status = status
    }

    public var listSelection: String? {
        get { navigation.listSelection }
        set { navigation.listSelection = newValue }
    }

    public func detail(_ id: String) -> DetailSnapshot? { details[id] }

    public func keyContext(textFieldFocused: Bool, popoverOpen: Bool, closedHeaderFocused: Bool) -> KeyContext {
        KeyContext(mode: navigation.selectedID == nil ? .list : .detail, textFieldFocused: textFieldFocused,
                   popoverOpen: popoverOpen, closedHeaderFocused: closedHeaderFocused)
    }

    public func perform(_ command: PanelCommand) {}
    public func open(_ id: String) { navigation.open(id) }
    public func back() { navigation.back() }
    public func close(_ id: String, _ verdict: Verdict) {}
    public func reopen(_ id: String) {}
    public func undo() {}
    public func refresh() {}
    public func setGrouping(_ grouping: QueueGrouping) {}
    public func setFilter(_ project: String?) {}
    public func toggleTick(_ path: String, in id: String) {}
    public func sendReply(_ id: String) {}
    public func sendChoice(_ id: String) {}
    public func sendAndDone(_ id: String) {}
    public func dismissNotice() {}
    public func performNoticeAction() {}
    public func copyLink(_ id: String) {}
    public func retryDetail(_ id: String) {}
}
