import Foundation
import RelayCore

/// Everything the queue view draws, as values.
public struct QueueSnapshot: Equatable, Sendable {
    public var content: PanelContent
    public var title: String
    public var grouping: QueueGrouping
    public var filter: String?
    public var sections: [QueueSection]
    public var rows: [String: AskRowModel]
    public var closed: [AskRowModel]
    public var hidden: HiddenCount
    public var projects: [MenuProject]
    public var manualRefreshing: Bool
    public var updated: String
    public var sourceName: String

    /// Shared by the Store and the gallery fixtures.
    public static func build(open: [WireItem], closed: [WireItem], grouping: QueueGrouping, filter: String?,
                             ticks: (String) -> Set<String>, drafts: [String: String], closedBy: (WireItem) -> String?,
                             sourceKey: String, loadedOnce: Bool, reachable: Bool, problem: String?, waitedTenSeconds: Bool,
                             manualRefreshing: Bool, updated: String) -> QueueSnapshot {
        let sections = QueueLayout.sections(items: open, grouping: grouping, filter: filter)
        let shown = sections.flatMap(\.items)
        var rows: [String: AskRowModel] = [:]
        for item in shown {
            rows[item.id] = row(item, ticked: ticks(item.id), hasDraft: hasText(drafts[item.id]), closedBy: nil)
        }
        let closedRows = QueueLayout.closed(closed, filter: filter).map {
            row($0, ticked: ticks($0.id), hasDraft: false, closedBy: closedBy($0))
        }
        let content = PanelContent.resolve(sourceKey: sourceKey, loadedOnce: loadedOnce, reachable: reachable, problem: problem,
                                           waitedTenSeconds: waitedTenSeconds, filter: filter,
                                           shownOpen: shown.count, shownClosed: closedRows.count)
        return QueueSnapshot(
            content: content, title: shown.isEmpty ? "Queue" : "\(shown.count) waiting", grouping: grouping, filter: filter,
            sections: sections, rows: rows, closed: closedRows,
            hidden: QueueLayout.hiddenCount(items: open, filter: filter),
            projects: QueueLayout.menuProjects(items: open, filter: filter),
            manualRefreshing: manualRefreshing, updated: updated,
            sourceName: sourceKey == SourceKey.local ? "This Mac" : "Mailbox")
    }

    /// One row; a non-open item gets its ClosedInfo, with `closedBy` the closing actor when known.
    public static func row(_ item: WireItem, ticked: Set<String>, hasDraft: Bool, closedBy: String?) -> AskRowModel {
        let isClosed = item.status != "open"
        return AskRowModel(
            id: item.id, title: item.title, project: item.projectId ?? "", urgency: Urgency(raw: item.urgency),
            created: item.created, summary: QueueLayout.summary(for: item, ticked: ticked),
            subline: SubLine.text(for: item, ticked: ticked), hasDraft: hasDraft,
            closed: isClosed ? ClosedInfo(status: item.status, closedBy: closedBy, completedAt: item.completedAt) : nil,
            resumeCommand: AskOrigin(from: item.instructable?.from)?.resumeCommand)
    }

    static func hasText(_ text: String?) -> Bool {
        !(text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// Everything the detail view draws for one ask.
public struct DetailSnapshot: Equatable, Sendable {
    public var id: String
    public var row: AskRowModel
    public var model: DetailModel?
    public var load: DetailLoadState
    public var ticks: Set<String>
    public var current: String?
    public var progress: StepProgress
    public var replies: [ReplyLine]
    public var sentChoices: Set<Int>
    public var latestSentChoice: Int?
    public var reply: ReplyBoxState
    public var primary: PrimaryAction
    public var busy: Bool
    public var previous: Neighbour
    public var next: Neighbour
    public var closedText: String?

    public static func build(item: WireItem, detail: AskDetail?, ticks: Set<String>, load: DetailLoadState,
                             reply: ReplyBoxState, draft: String?, pendingChoice: Int?, busy: Bool,
                             previous: Neighbour, next: Neighbour, closedBy: String?) -> DetailSnapshot {
        let model = detail.map(DetailModel.make)
        let nodes = model?.nodes ?? []
        let events = detail?.events ?? []
        let choices = item.instructable?.reply?.choices ?? []
        let latest = ReplyText.latestSentChoice(events: events, choices: choices)
        let isOpen = item.status == "open"
        return DetailSnapshot(
            id: item.id,
            row: QueueSnapshot.row(item, ticked: ticks, hasDraft: QueueSnapshot.hasText(draft), closedBy: model?.closedBy ?? closedBy),
            model: model, load: load, ticks: ticks,
            current: Flow.currentStep(ticks: ticks, nodes: nodes), progress: Flow.progress(ticks: ticks, nodes: nodes),
            replies: ReplyText.lines(events: events), sentChoices: ReplyText.sentChoices(events: events, choices: choices),
            latestSentChoice: latest, reply: reply,
            primary: Flow.primaryAction(draft: draft, choice: pendingChoice, sent: latest), busy: busy,
            previous: previous, next: next,
            closedText: isOpen ? nil : ClosedText.detail(status: item.status, closedBy: model?.closedBy ?? closedBy,
                                                        closedAt: model?.closedAt ?? item.completedAt))
    }
}
