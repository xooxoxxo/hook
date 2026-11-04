import Foundation
import RelayCore

/// Everything the queue view draws, as values.
public struct QueueSnapshot: Equatable, Sendable {
    public var content: PanelContent
    /// Always "Queue": the count lives in the menu-bar tooltip and VoiceOver labels.
    public var title: String
    /// The open asks shown (after the filter), for the header's VoiceOver label.
    public var waiting: Int = 0
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
                             review: (WireItem) -> ReviewState = { _ in .legacy },
                             doneBlocked: (WireItem) -> Bool = { _ in false },
                             sourceKey: String, loadedOnce: Bool, reachable: Bool, problem: String?, waitedTenSeconds: Bool,
                             manualRefreshing: Bool, updated: String) -> QueueSnapshot {
        var rows: [String: AskRowModel] = [:]
        var shownCount = 0
        for section in sections {
            for item in section.items {
                shownCount += 1
                rows[item.id] = row(item, ticked: ticks(item), answered: answered(item), hasDraft: hasDraft(item.id),
                                    closedBy: nil, review: review(item), doneBlocked: doneBlocked(item))
            }
        }
        let closedRows = shownClosed.map {
            row($0, ticked: ticks($0), answered: answered($0), hasDraft: false, closedBy: closedBy($0), review: review($0))
        }
        let content = PanelContent.resolve(sourceKey: sourceKey, loadedOnce: loadedOnce, reachable: reachable, problem: problem,
                                           waitedTenSeconds: waitedTenSeconds, filter: filter,
                                           shownOpen: shownCount, shownClosed: closedRows.count)
        return QueueSnapshot(
            content: content, title: "Queue", waiting: shownCount, grouping: grouping, filter: filter,
            sections: sections, rows: rows, closed: closedRows,
            hidden: QueueLayout.hiddenCount(items: open, filter: filter),
            projects: QueueLayout.menuProjects(items: open, filter: filter),
            manualRefreshing: manualRefreshing, updated: updated,
            sourceName: sourceKey == SourceKey.local ? "This Mac" : "Pond")
    }

    /// One row; a non-open item gets its ClosedInfo, with `closedBy` the closing actor when known.
    /// `answered`: the answered step paths, when the ask's detail is cached (QueueLayout.summary).
    /// `doneBlocked`: the queue's Done is off for this ask (`AskRowModel.doneBlocked`).
    public static func row(_ item: WireItem, ticked: Set<String>, answered: Set<String>? = nil, hasDraft: Bool,
                           closedBy: String?, review: ReviewState = .legacy, doneBlocked: Bool = false) -> AskRowModel {
        let isClosed = item.status != "open"
        let summary = QueueLayout.summary(for: item, ticked: ticked, answered: answered)
        let ins = item.instructable
        let origin = AskOrigin(from: ins?.from)
        var row = AskRowModel(
            id: item.id, title: item.title, project: item.projectId ?? "", urgency: Urgency(raw: item.urgency),
            created: item.created, summary: summary,
            subline: SubLine.text(summary, choices: ins?.reply?.choices?.count ?? 0, places: ins.map(SubLine.places) ?? []),
            hasDraft: hasDraft,
            closed: isClosed ? ClosedInfo(status: item.status, closedBy: closedBy, completedAt: item.completedAt) : nil,
            resumeCommand: origin?.resumeCommand, origin: origin, review: review)
        row.doneBlocked = !isClosed && doneBlocked
        return row
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
    /// Where the ask stands with this Mac's review of its corrections.
    public var review: ReviewState = .legacy
    /// The revision this snapshot renders; nil for a legacy ask or a failed history.
    public var stamp: RevisionStamp?
    /// The whole ask is locked: a correction is unreviewed or its history changed. No copy,
    /// link, file, Done, answer, reply or tick; Skip still works.
    public var locked: Bool { review.isLocked }
    /// The review entry point, from the state alone, so a later Notice never hides it.
    public var reviewAction: ReviewAction? { review.action }
    /// After an accept: the paths of steps that changed or were added, until ticked.
    public var changedSteps: [String: StepChip] = [:]
    /// Paths with a problem report the step hasn't been corrected since.
    public var reported: Set<String> = []
    /// Report a Problem is offered: an open ask from a Pond (never This Mac).
    public var canReport = false
    /// The step path the docked composer reports on, while it is open.
    public var reportTarget: String?
    /// The composer's send state.
    public var report: ReportBoxState = .idle
    /// This Mac has an approved owner key: the composer's button is Send, else Set Up Owner Key….
    /// Read only while the composer is open.
    public var ownerKeyReady = false
    /// The owner's messages to the session, oldest first (never replies).
    public var messages: [ReplyLine] = []
    /// The Messages send state.
    public var message: MessageBoxState = .idle
    /// The Messages section shows: a Pond with messages (1.2.0 or later), never This Mac. On a
    /// closed ask the earlier messages stay, read-only.
    public var canMessage = false
    /// How long a message or a report may be (8000 on Pond 1.4.0, else 1000 and 300), and
    /// whether a report keeps its lines.
    public var limits: TalkLimits = .old
    /// While a correction is pending: how many steps it adds to the version shown.
    public var addedSinceShown = 0
    /// What the ask needs before Done and what's left (Pond 1.3.0); `.none` without requirements,
    /// before the detail loads, or once closed. The rows' marks read `marks(path)`.
    public var requirements: RequirementState = .none
    /// Done may be pressed (`Requirements.doneAvailable`): nothing is left, or only what the
    /// unsent drafts finish. Always true on an ask without requirements.
    public var doneEnabled = true
    /// The warning's Discard & Done may be pressed: nothing is left without the drafts.
    public var discardEnabled = true
    /// The bar that replaces the action bar while the ask is locked and not under review.
    public var lockBar: ReviewLockBar? { ReviewLockBar.make(review) }

    public static func build(item: WireItem, detail: AskDetail?, ticks: Set<String>, load: DetailLoadState,
                             reply: ReplyBoxState, draft: String?, pendingChoice: Int?, busy: Bool,
                             previous: Neighbour, next: Neighbour, closedBy: String?,
                             answerDrafts: [String: AnswerDraft] = [:], answerState: AnswerSendState? = nil,
                             doneWarning: Bool = false, review: ReviewState = .legacy,
                             stamp: RevisionStamp? = nil, history: VerifiedHistory? = nil,
                             chips: [String: StepChip] = [:], reported: Set<String> = [],
                             addedSinceShown: Int = 0) -> DetailSnapshot {
        let model = detail.map { DetailModel.make(item: $0.item, events: $0.events, history: history) }
        let nodes = model?.nodes ?? []
        let events = detail?.events ?? []
        let choices = item.instructable?.reply?.options ?? []
        let latest = ReplyText.latestSentChoice(events: events, choices: choices)
        let isOpen = item.status == "open"
        let locked = Set(Flow.lockedPaths(nodes: nodes, ticks: ticks))
        let unsent = isOpen ? AnswerDrafts.unsent(answerDrafts, nodes: nodes, locked: locked) : .none
        let replies = ReplyText.lines(events: events)
        let messages = MessageText.lines(events: events)
        let answered = model.map { Set(Flow.flattened($0.nodes).compactMap { $0.answer?.step }) }
        let kind = isOpen ? Flow.unsentKind(draft: draft, choice: pendingChoice, sent: latest, unsentAnswers: unsent.count,
                                            sentText: AnswerEditing.latestText(replies)) : nil
        // Requirements (Pond 1.3.0): without a detail, an ask that declares them keeps Done off.
        let declared = isOpen && Requirements.declared(item.instructable)
        let requirements = declared ? model.map { Requirements.state($0, ticks: ticks) } ?? .none : .none
        let replyUnsent = Flow.unsentKind(draft: draft, choice: pendingChoice, sent: latest,
                                          sentText: AnswerEditing.latestText(replies)) == .reply
        var snapshot = DetailSnapshot(
            id: item.id,
            row: QueueSnapshot.row(item, ticked: ticks, answered: answered, hasDraft: QueueSnapshot.hasText(draft),
                                   closedBy: model?.closedBy ?? closedBy, review: review),
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
            unansweredCaption: isOpen && !declared ? AnswerDrafts.unansweredCaption(
                AnswerDrafts.uncovered(unanswered: model?.unanswered ?? [], unsent: unsent)) : nil,
            unsentKind: kind, doneWarning: doneWarning && kind != nil, review: review, stamp: stamp,
            changedSteps: chips, reported: reported, messages: messages, addedSinceShown: addedSinceShown)
        snapshot.requirements = requirements
        snapshot.doneEnabled = !declared
            || (model != nil && Requirements.doneAvailable(requirements, unsent: unsent, replyUnsent: replyUnsent))
        snapshot.discardEnabled = !declared || (model != nil && requirements.ready)
        return snapshot
    }
}
