import Foundation
import RelayCore

/// What the AppKit shell does for the panel.
public struct PanelShellActions: Sendable {
    public var hide, setUp, quit: @MainActor @Sendable () -> Void
    public var dock: @MainActor @Sendable (SidebarEdge) -> Void
    public var openSettings: @MainActor @Sendable (SettingsTabID?) -> Void
    public var copy: @MainActor @Sendable (String) -> Void
    public var openURL: @MainActor @Sendable (URL) -> Void
    /// Resume Session: opens a terminal in the session's folder.
    public var resume: @MainActor @Sendable (AskOrigin) -> Void

    public init(hide: @escaping @MainActor @Sendable () -> Void, setUp: @escaping @MainActor @Sendable () -> Void,
                quit: @escaping @MainActor @Sendable () -> Void, dock: @escaping @MainActor @Sendable (SidebarEdge) -> Void,
                openSettings: @escaping @MainActor @Sendable (SettingsTabID?) -> Void,
                copy: @escaping @MainActor @Sendable (String) -> Void, openURL: @escaping @MainActor @Sendable (URL) -> Void,
                resume: @escaping @MainActor @Sendable (AskOrigin) -> Void = { _ in }) {
        self.hide = hide
        self.setUp = setUp
        self.quit = quit
        self.dock = dock
        self.openSettings = openSettings
        self.copy = copy
        self.openURL = openURL
        self.resume = resume
    }

    public static let none = PanelShellActions(hide: {}, setUp: {}, quit: {}, dock: { _ in }, openSettings: { _ in },
                                               copy: { _ in }, openURL: { _ in })
}

/// The panel views' only way to the model. The Store conforms;
/// FixturePanelModel serves the gallery.
@MainActor public protocol PanelViewModel: ObservableObject {
    var queue: QueueSnapshot { get }
    func detail(_ id: String) -> DetailSnapshot?
    var navigation: PanelNavigation { get }
    var listSelection: String? { get set }
    var drafts: [String: String] { get set }
    var pendingChoice: [String: Int] { get set }
    /// Unsent step answers per ask, then step path (memory only).
    var answerDrafts: [String: [String: AnswerDraft]] { get set }
    var expandedDone: [String: Set<String>] { get set }
    /// Asks whose sent reply is being changed (memory only).
    var editingReply: Set<String> { get set }
    /// Answered step questions being changed, per ask, by path (memory only).
    var editingAnswers: [String: Set<String>] { get set }
    /// Upcoming steps expanded by hand, per ask (memory only).
    var expandedTodo: [String: Set<String>] { get set }
    var detailAnchor: [String: String] { get set }
    var notice: PanelNotice? { get }
    var undoInfo: UndoInfo? { get }
    var status: PanelStatus { get }
    /// Held closes being sent on quit; the Undo bar shows "Sending" while it is above 0.
    var sendingCloses: Int { get }
    var shell: PanelShellActions { get }
    func keyContext(textFieldFocused: Bool, popoverOpen: Bool, closedHeaderFocused: Bool) -> KeyContext
    func perform(_ command: PanelCommand)
    func open(_ id: String)
    func back()
    func close(_ id: String, _ verdict: Verdict)
    func reopen(_ id: String)
    func undo()
    func refresh()
    func setGrouping(_ grouping: QueueGrouping)
    func setFilter(_ project: String?)
    func toggleTick(_ path: String, in id: String)
    func sendReply(_ id: String)
    func sendChoice(_ id: String)
    /// Send & Done in the Done warning: sends what is unsent, then closes.
    func sendAndDone(_ id: String)
    /// Done with something unsent: shows the bar's warning instead of closing.
    func warnUnsent(_ id: String)
    /// Discard & Done in the Done warning: drops the unsent text, picks and answers, then closes.
    func discardAndDone(_ id: String)
    /// Esc in the Done warning: back to editing, nothing sent or dropped.
    func cancelDoneWarning(_ id: String)
    /// ⌘S: sends the open ask's unsent step answers.
    func sendAnswers(_ id: String)
    /// One question's own Send (and Return in its field): sends that step's unsent answer.
    func sendAnswer(_ id: String, path: String)
    func dismissNotice()
    func performNoticeAction()
    func copyLink(_ id: String)
    func retryDetail(_ id: String)
}

/// Change and Cancel on an answered reply or step question. Edit state lives in the model,
/// in memory only; a successful send leaves it (the Store does that).
extension PanelViewModel {
    /// The reply comes back prefilled: the latest choice picked, or the latest text as the draft.
    public func changeReply(_ id: String) {
        guard let snapshot = detail(id) else { return }
        let prefill = AnswerEditing.replyPrefill(replies: snapshot.replies,
                                                 hasChoices: !(snapshot.model?.reply?.choices ?? []).isEmpty,
                                                 latestSentChoice: snapshot.latestSentChoice)
        drafts[id] = prefill.draft
        pendingChoice[id] = prefill.choice
        editingReply.insert(id)
    }

    /// Back to the answer row; the unsent text or pick goes.
    public func cancelReplyChange(_ id: String) {
        editingReply.remove(id)
        drafts[id] = nil
        pendingChoice[id] = nil
    }

    /// The question's control comes back, starting from the sent answer.
    public func changeAnswer(_ id: String, path: String) {
        editingAnswers[id, default: []].insert(path)
    }

    /// Back to the answered row; the unsent draft at `path` goes.
    public func cancelAnswerChange(_ id: String, path: String) {
        var paths = editingAnswers[id] ?? []
        paths.remove(path)
        editingAnswers[id] = paths.isEmpty ? nil : paths
        guard var drafts = answerDrafts[id] else { return }
        drafts[path] = nil
        answerDrafts[id] = drafts.isEmpty ? nil : drafts
    }
}
