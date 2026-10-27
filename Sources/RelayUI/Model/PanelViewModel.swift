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
    func sendAndDone(_ id: String)
    /// ⌘S / Send answers: sends the open ask's unsent step answers.
    func sendAnswers(_ id: String)
    func dismissNotice()
    func performNoticeAction()
    func copyLink(_ id: String)
    func retryDetail(_ id: String)
}
