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
    /// Update Mailbox…: runs the update command in a terminal, or opens the guide.
    public var updateMailbox: @MainActor @Sendable () -> Void = {}
    /// Check for Updates (Hook's own release check).
    public var checkForUpdates: @MainActor @Sendable () -> Void = {}
    /// Report a Problem's Set Up Owner Key…: opens Settings › Queue and starts the owner key setup.
    public var setUpOwnerKey: @MainActor @Sendable () -> Void = {}
    /// The status bar's profile switch: saves `source` through the same merge-save as
    /// Settings › Queue.
    public var switchSource: @MainActor @Sendable (SourceKind) -> Void = { _ in }
    /// A file row's Open, Open With, Reveal in Finder, and its file checks.
    public var files: FileActions = .none
    /// Touch ID, or the login password (so it works while screen sharing), with the reason
    /// macOS shows ("accept a changed command, link or file in …"). False when refused or unavailable.
    public var confirmPresence: @MainActor @Sendable (String) async -> Bool = { _ in false }

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

/// What a guarded copy did: `.refused` when the ask changed under the click (a correction
/// arrived or is unreviewed), so the block says "Changed just now. Review first." instead of "Copied".
public enum CopyOutcome: Equatable, Sendable {
    case copied, refused

    public static let refusedText = "Changed just now. Review first."
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
    /// This Mac's host name for Resume Session's "is this session here" check; the app reads
    /// it at launch (and again when the panel becomes key), never per row.
    var localHost: String? { get }
    /// Hook reads This Mac's queue (not a mailbox): a file link in an ask without a host is here.
    var queueIsLocal: Bool { get }
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
    /// The Notice's second button ("How to update").
    func performNoticeSecondaryAction()
    func copyLink(_ id: String)
    func retryDetail(_ id: String)
    /// A command's Copy: copies only while the ask is current at `stamp` (the revision the
    /// snapshot rendered) and `text` is a command of that revision.
    @discardableResult func copyCode(_ id: String, stamp: RevisionStamp?, text: String) -> CopyOutcome
    /// Any link the detail shows (a step's, a link, Markdown in a detail): opens only under the
    /// same rule as `copyCode`.
    func openStepURL(_ id: String, stamp: RevisionStamp?, url: URL)
    /// Copy Link Address, under the same rule.
    @discardableResult func copyLinkAddress(_ id: String, stamp: RevisionStamp?, url: URL) -> CopyOutcome
    /// A file row's Open, Open With, Reveal in Finder and Copy Path, under the same rule, for a
    /// file (`path` as sent) the rendered revision names. Asked at the moment each one acts.
    func allowsFileAction(_ id: String, stamp: RevisionStamp?, path: String) -> Bool
    /// Where the ask stands with this Mac's review of its corrections.
    func reviewState(_ id: String) -> ReviewState
    /// The version each ask's inline review shows (memory only); nil when not under review.
    var reviewing: [String: RevisionStamp] { get set }
    /// The inline review of `reviewing[id]` (else the current version); nil when the ask isn't
    /// pending or its history hasn't arrived yet.
    func reviewPage(_ id: String) -> ReviewPage?
    /// Use Version N: accepts exactly `stamp` (Touch ID when a command, link or file changed).
    func accept(_ id: String, stamp: RevisionStamp)
    /// An accept of this ask is in flight: Use Version N is off.
    func isAccepting(_ id: String) -> Bool
    /// Report a Problem…'s Send: one step's note to the posting session, quoted.
    func reportProblem(_ id: String, stepID: String, note: String)
    /// What this source lets Hook say to the posting session; nothing on This Mac.
    var talk: SessionTalk { get }
    /// The docked report composer, by ask: the step path it reports on (memory only).
    var reporting: [String: String] { get set }
    /// Opens the composer on `path` and the ask's detail; nil (the queue row's Report a
    /// Problem…) picks the first unticked actionable step.
    func beginReport(_ id: String, path: String?)
    /// Esc or Cancel: the composer goes, and a held note with it.
    func endReport(_ id: String)
    /// The composer's Send, or Set Up Owner Key… without an approved key (the note is held).
    func sendReport(_ id: String, note: String)
    /// The Messages field's text, by ask (memory only).
    var messageDrafts: [String: String] { get set }
    /// The ask whose Messages field has focus, or should take it (⌘L, Message Session…).
    var messageFocus: String? { get set }
    /// The Messages field's Send (and ⌘Return in it): the text as typed.
    func sendMessage(_ id: String, text: String)
    /// The queue row's Message Session…: opens the ask and focuses its Messages field.
    func messageSession(_ id: String)
    /// "Trust the Pond's History Again…" (Touch ID): after a Pond restore, re-pin what it serves now.
    func trustHistoryAgain()
    /// The last run crashed and the bar offers a report; nil once answered.
    var crashOffer: CrashOffer? { get }
    /// Review…: opens the send sheet.
    func reviewCrash()
    /// The send sheet: target, exactly what is sent, the send's state; nil while closed.
    var crashSheet: CrashSheetModel? { get }
    /// The sheet's primary button, for its target.
    func sendCrashReport()
    func setCrashTarget(_ target: CrashTarget)
    /// Cancel: the sheet goes, the bar stays.
    func closeCrashSheet()
    func copyCrashReport()
    func showCrashReportInFinder()
    /// GitHub couldn't be searched: open a new issue, or look by hand (the sheet stays).
    func openNewCrashIssue()
    func checkExistingCrashIssue()
    /// Not Now: the bar goes and the signature is marked handled.
    func dismissCrash()
    /// The status bar's profile switcher.
    var profiles: ProfileMenu { get }
    func switchProfile(_ kind: SourceKind)
}

/// Show Changes, Not Now and Show Version N+1: the inline review is view state in the model.
extension PanelViewModel {
    /// Reviews the current version; again after a newer one arrived, it re-diffs and never accepts the older.
    public func startReview(_ id: String) {
        guard case .pending(_, let current, _) = reviewState(id) else { return }
        reviewing[id] = current
    }

    /// Not Now: back to the locked ask.
    public func endReview(_ id: String) {
        reviewing[id] = nil
    }

    /// The detail shows the inline review: Show Changes was pressed and the ask is still pending.
    public func isReviewing(_ id: String) -> Bool {
        guard reviewing[id] != nil, case .pending = reviewState(id) else { return false }
        return true
    }
}

extension PanelViewModel {
    /// The queue row's Report a Problem…: the first unticked actionable step.
    public func beginReport(_ id: String) { beginReport(id, path: nil) }
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
