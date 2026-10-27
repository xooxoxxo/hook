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
        build(sections: QueueLayout.sections(items: open, grouping: grouping, filter: filter),
              shownClosed: QueueLayout.closed(closed, filter: filter), open: open, grouping: grouping, filter: filter,
              ticks: { ticks($0.id) }, answered: { _ in nil }, hasDraft: { hasText(drafts[$0]) }, closedBy: closedBy,
              sourceKey: sourceKey, loadedOnce: loadedOnce, reachable: reachable, problem: problem,
              waitedTenSeconds: waitedTenSeconds, manualRefreshing: manualRefreshing, updated: updated)
    }

    /// From sections and closed rows the caller has laid out already (the Store keeps them).
    public static func build(sections: [QueueSection], shownClosed: [WireItem], open: [WireItem],
                             grouping: QueueGrouping, filter: String?,
                             ticks: (WireItem) -> Set<String>, answered: (WireItem) -> Set<String>?,
                             hasDraft: (String) -> Bool, closedBy: (WireItem) -> String?,
                             sourceKey: String, loadedOnce: Bool, reachable: Bool, problem: String?, waitedTenSeconds: Bool,
                             manualRefreshing: Bool, updated: String) -> QueueSnapshot {
        var rows: [String: AskRowModel] = [:]
        var shownCount = 0
        for section in sections {
            for item in section.items {
                shownCount += 1
                rows[item.id] = row(item, ticked: ticks(item), answered: answered(item), hasDraft: hasDraft(item.id),
                                    closedBy: nil)
            }
        }
        let closedRows = shownClosed.map {
            row($0, ticked: ticks($0), answered: answered($0), hasDraft: false, closedBy: closedBy($0))
        }
        let content = PanelContent.resolve(sourceKey: sourceKey, loadedOnce: loadedOnce, reachable: reachable, problem: problem,
                                           waitedTenSeconds: waitedTenSeconds, filter: filter,
                                           shownOpen: shownCount, shownClosed: closedRows.count)
        return QueueSnapshot(
            content: content, title: shownCount == 0 ? "Queue" : "\(shownCount) waiting", grouping: grouping, filter: filter,
            sections: sections, rows: rows, closed: closedRows,
            hidden: QueueLayout.hiddenCount(items: open, filter: filter),
            projects: QueueLayout.menuProjects(items: open, filter: filter),
            manualRefreshing: manualRefreshing, updated: updated,
            sourceName: sourceKey == SourceKey.local ? "This Mac" : "Mailbox")
    }

    /// One row; a non-open item gets its ClosedInfo, with `closedBy` the closing actor when known.
    /// `answered`: the answered step paths, when the ask's detail is cached (QueueLayout.summary).
    public static func row(_ item: WireItem, ticked: Set<String>, answered: Set<String>? = nil, hasDraft: Bool,
                           closedBy: String?) -> AskRowModel {
        let isClosed = item.status != "open"
        let summary = QueueLayout.summary(for: item, ticked: ticked, answered: answered)
        let ins = item.instructable
        let origin = AskOrigin(from: ins?.from)
        return AskRowModel(
            id: item.id, title: item.title, project: item.projectId ?? "", urgency: Urgency(raw: item.urgency),
            created: item.created, summary: summary,
            subline: SubLine.text(summary, choices: ins?.reply?.choices?.count ?? 0, places: ins.map(SubLine.places) ?? []),
            hasDraft: hasDraft,
            closed: isClosed ? ClosedInfo(status: item.status, closedBy: closedBy, completedAt: item.completedAt) : nil,
            resumeCommand: origin?.resumeCommand, origin: origin)
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
    /// The step answers drafted here, by path (memory only, in the model).
    public var answerDrafts: [String: AnswerDraft] = [:]
    /// What ⌘S would send now (locked steps left out); none while the ask is closed.
    public var unsent: UnsentAnswers = .none
    /// The answers send in flight, or its failure.
    public var answerState: AnswerSendState?
    /// "2 questions unanswered" (R6), while unanswered questions have no unsent draft.
    public var unansweredCaption: String?
    /// What Done would leave unsent (Flow.unsentKind); nil when nothing is, or the ask is closed.
    public var unsentKind: UnsentKind?
    /// Done was pressed with `unsentKind` set: the bar warns (Send & Done, Discard & Done).
    /// Never true without an `unsentKind`.
    public var doneWarning = false

    public static func build(item: WireItem, detail: AskDetail?, ticks: Set<String>, load: DetailLoadState,
                             reply: ReplyBoxState, draft: String?, pendingChoice: Int?, busy: Bool,
                             previous: Neighbour, next: Neighbour, closedBy: String?,
                             answerDrafts: [String: AnswerDraft] = [:], answerState: AnswerSendState? = nil,
                             doneWarning: Bool = false) -> DetailSnapshot {
        let model = detail.map(DetailModel.make)
        let nodes = model?.nodes ?? []
        let events = detail?.events ?? []
        let choices = item.instructable?.reply?.choices ?? []
        let latest = ReplyText.latestSentChoice(events: events, choices: choices)
        let isOpen = item.status == "open"
        let locked = Set(Flow.lockedPaths(nodes: nodes, ticks: ticks))
        let unsent = isOpen ? AnswerDrafts.unsent(answerDrafts, nodes: nodes, locked: locked) : .none
        let replies = ReplyText.lines(events: events)
        let answered = model.map { Set(Flow.flattened($0.nodes).compactMap { $0.answer?.step }) }
        let kind = isOpen ? Flow.unsentKind(draft: draft, choice: pendingChoice, sent: latest, unsentAnswers: unsent.count,
                                            sentText: AnswerEditing.latestText(replies)) : nil
        return DetailSnapshot(
            id: item.id,
            row: QueueSnapshot.row(item, ticked: ticks, answered: answered, hasDraft: QueueSnapshot.hasText(draft),
                                   closedBy: model?.closedBy ?? closedBy),
            model: model, load: load, ticks: ticks,
            current: Flow.currentStep(ticks: ticks, nodes: nodes), progress: Flow.progress(ticks: ticks, nodes: nodes),
            replies: replies, sentChoices: ReplyText.sentChoices(events: events, choices: choices),
            latestSentChoice: latest, reply: reply,
            primary: kind == nil ? .done : .sendAndDone,
            busy: busy || answerState == .sending,
            previous: previous, next: next,
            closedText: isOpen ? nil : ClosedText.detail(status: item.status, closedBy: model?.closedBy ?? closedBy,
                                                        closedAt: model?.closedAt ?? item.completedAt),
            answerDrafts: answerDrafts, unsent: unsent, answerState: answerState,
            unansweredCaption: isOpen ? AnswerDrafts.unansweredCaption(
                AnswerDrafts.uncovered(unanswered: model?.unanswered ?? [], unsent: unsent)) : nil,
            unsentKind: kind, doneWarning: doneWarning && kind != nil)
    }
}
