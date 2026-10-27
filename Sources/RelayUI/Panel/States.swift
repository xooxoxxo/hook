import RelayCore
import SwiftUI

/// Which StateView takes the list area. Each state has one place and one
/// text; the list itself (`.list`) has none. Reasons go through UserFacingError.
enum PanelStateMapping {
    static func kind(_ content: PanelContent, sourceName: String, updated: String) -> StateKind? {
        switch content {
        case .list:
            return nil
        case .loading(let stillTrying):
            return .loading(source: sourceName, stillTrying: stillTrying)
        case .notSetUp:
            return .notSetUp
        case .offline(let local, let reason):
            return .offline(title: local ? "This Mac isn't ready" : "Can't reach the Pond",
                            reason: UserFacingError.text(reason))
        case .empty:
            return .empty(updated: updated)
        case .emptyFiltered(let project):
            return .emptyFiltered(project: project, updated: updated)
        }
    }

    /// The state views' buttons. "Show Closed Ask" opens `closedID` (the not-found detail).
    @MainActor static func actions<Model: PanelViewModel>(_ model: Model, closedID: String? = nil) -> StateActions {
        StateActions(
            settings: { model.shell.openSettings(.queue) },
            tryAgain: { model.refresh() },
            setUp: { model.shell.setUp() },
            showAll: { model.setFilter(nil) },
            backToQueue: { model.back() },
            showClosed: { if let closedID { model.open(closedID) } })
    }
}
