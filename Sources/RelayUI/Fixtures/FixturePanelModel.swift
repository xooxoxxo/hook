import Foundation
import RelayCore

/// A PanelViewModel over fixed snapshots, for the gallery. Actions don't change the
/// snapshots (each scene is one state); view state (selection, drafts…) is kept.
public final class FixturePanelModel: PanelViewModel {
    @Published public var queue: QueueSnapshot
    @Published public var navigation: PanelNavigation
    @Published public var drafts: [String: String] = [:]
    @Published public var pendingChoice: [String: Int] = [:]
    @Published public var answerDrafts: [String: [String: AnswerDraft]] = [:]
    @Published public var expandedDone: [String: Set<String>] = [:]
    @Published public var editingReply: Set<String> = []
    @Published public var editingAnswers: [String: Set<String>] = [:]
    @Published public var expandedTodo: [String: Set<String>] = [:]
    @Published public var detailAnchor: [String: String] = [:]
    @Published public var reviewing: [String: RevisionStamp] = [:]
    @Published public var reporting: [String: String] = [:]
    @Published public var notice: PanelNotice?
    @Published public var undoInfo: UndoInfo?
    @Published public var status: PanelStatus
    @Published public var sendingCloses = 0
    @Published public var crashOffer: CrashOffer?
    @Published public var crashSheet: CrashSheetModel?
    @Published public var profiles: ProfileMenu
    public var shell = PanelShellActions.none
    public var localHost: String?
    public var queueIsLocal = false
    public var talk = SessionTalk(reports: true)
    private let details: [String: DetailSnapshot]
    private let reviewPages: [String: ReviewPage]

    public init(queue: QueueSnapshot, details: [String: DetailSnapshot] = [:], navigation: PanelNavigation = .init(),
                notice: PanelNotice? = nil, undo: UndoInfo? = nil, status: PanelStatus,
                reviewPages: [String: ReviewPage] = [:], crashOffer: CrashOffer? = nil,
                profiles: ProfileMenu = FixturePanelModel.pondProfiles) {
        self.queue = queue
        self.details = details
        self.reviewPages = reviewPages
        reviewing = reviewPages.mapValues(\.target)
        self.navigation = navigation
        self.notice = notice
        undoInfo = undo
        self.status = status
        self.crashOffer = crashOffer
        self.profiles = profiles
    }

    /// This Mac and a Pond named by the default context, the Pond shown.
    public static let pondProfiles = ProfileMenu(
        profiles: [Profile(kind: .local, name: ProfileMenu.thisMac, current: false),
                   Profile(kind: .mailbox, name: "Personal", current: true)],
        readOnly: false, pondSaved: true)

    /// This Mac only, with no Pond saved (the menu offers Set Up a Pond…).
    public static let localProfiles = ProfileMenu(
        profiles: [Profile(kind: .local, name: ProfileMenu.thisMac, current: true)], readOnly: false, pondSaved: false)

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
    public func warnUnsent(_ id: String) {}
    public func discardAndDone(_ id: String) {}
    public func cancelDoneWarning(_ id: String) {}
    public func sendAnswers(_ id: String) {}
    public func sendAnswer(_ id: String, path: String) {}
    public func dismissNotice() {}
    public func performNoticeAction() {}
    public func performNoticeSecondaryAction() {}
    public func copyLink(_ id: String) {}
    public func retryDetail(_ id: String) {}
    /// The gallery copies what the fixture says; a locked snapshot refuses, as the Store does.
    @discardableResult public func copyCode(_ id: String, stamp: RevisionStamp?, text: String) -> CopyOutcome {
        guard details[id]?.locked != true else { return .refused }
        shell.copy(text)
        return .copied
    }
    public func openStepURL(_ id: String, stamp: RevisionStamp?, url: URL) {
        guard details[id]?.locked != true else { return }
        shell.openURL(url)
    }
    @discardableResult public func copyLinkAddress(_ id: String, stamp: RevisionStamp?, url: URL) -> CopyOutcome {
        guard details[id]?.locked != true else { return .refused }
        shell.copy(url.absoluteString)
        return .copied
    }
    public func allowsFileAction(_ id: String, stamp: RevisionStamp?, path: String) -> Bool {
        details[id]?.locked != true
    }
    public func reviewState(_ id: String) -> ReviewState { details[id]?.review ?? .legacy }
    public func reviewPage(_ id: String) -> ReviewPage? { reviewPages[id] }
    public func accept(_ id: String, stamp: RevisionStamp) {}
    /// The gallery's in-flight accepts.
    public var acceptingIDs: Set<String> = []
    public func isAccepting(_ id: String) -> Bool { acceptingIDs.contains(id) }
    public func reportProblem(_ id: String, stepID: String, note: String) {}
    public func beginReport(_ id: String, path: String?) { if let path { reporting[id] = path } }
    public func endReport(_ id: String) { reporting[id] = nil }
    public func sendReport(_ id: String, note: String) {}
    public func trustHistoryAgain() {}
    public func reviewCrash() {}
    public func dismissCrash() {}
    public func sendCrashReport() {}
    public func setCrashTarget(_ target: CrashTarget) { crashSheet?.target = target }
    public func closeCrashSheet() { crashSheet = nil }
    public func copyCrashReport() { crashSheet.map { shell.copy($0.preview) } }
    public func showCrashReportInFinder() {}
    public func openNewCrashIssue() {}
    public func checkExistingCrashIssue() {}
    public func switchProfile(_ kind: SourceKind) {}
}
