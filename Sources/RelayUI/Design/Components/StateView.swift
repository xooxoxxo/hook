import SwiftUI

/// The panel's full-area states. Each case carries its own texts.
public enum StateKind: Equatable, Sendable {
    /// `source` is the raw source name ("Pond" / "This Mac"); described as "From <source>".
    case loading(source: String, stillTrying: Bool)
    case empty(updated: String), emptyFiltered(project: String, updated: String)
    /// `title` is "Can't reach the mailbox" or "This Mac isn't ready".
    case offline(title: String, reason: String)
    case notSetUp, notFound(canShowClosed: Bool)
}

/// What the state buttons do. `none` is for the gallery and for states without buttons.
public struct StateActions: Sendable {
    public var settings, tryAgain, setUp, showAll, backToQueue, showClosed: @MainActor @Sendable () -> Void

    public init(settings: @escaping @MainActor @Sendable () -> Void, tryAgain: @escaping @MainActor @Sendable () -> Void,
                setUp: @escaping @MainActor @Sendable () -> Void, showAll: @escaping @MainActor @Sendable () -> Void,
                backToQueue: @escaping @MainActor @Sendable () -> Void, showClosed: @escaping @MainActor @Sendable () -> Void) {
        self.settings = settings
        self.tryAgain = tryAgain
        self.setUp = setUp
        self.showAll = showAll
        self.backToQueue = backToQueue
        self.showClosed = showClosed
    }

    public static let none = StateActions(settings: {}, tryAgain: {}, setUp: {}, showAll: {}, backToQueue: {}, showClosed: {})
}

/// A stock ContentUnavailableView per state: symbol, title, one-line description, buttons.
public struct StateView: View {
    let kind: StateKind
    let actions: StateActions

    public init(_ kind: StateKind, actions: StateActions) {
        self.kind = kind
        self.actions = actions
    }

    public var body: some View {
        switch kind {
        case .loading(_, let stillTrying):
            ContentUnavailableView {
                ProgressView { Text(Self.title(kind)) }.accessibilityLabel("Loading asks")
            } description: {
                Text(Self.description(kind))
            } actions: {
                if stillTrying { Button("Queue Settings…", action: actions.settings).controlSize(DS.Control.form) }
            }
        case .offline:
            ContentUnavailableView {
                Label(Self.title(kind), systemImage: DS.Symbol.offline)
            } description: {
                Text(Self.description(kind)).lineLimit(4)
            } actions: {
                buttons
            }
        case .empty, .emptyFiltered, .notSetUp, .notFound:
            ContentUnavailableView {
                Label(Self.title(kind), systemImage: symbol)
            } description: {
                Text(Self.description(kind))
            } actions: {
                buttons
            }
        }
    }

    private var symbol: String {
        switch kind {
        case .loading, .empty, .emptyFiltered: return DS.Symbol.empty
        case .offline: return DS.Symbol.offline
        case .notSetUp: return DS.Symbol.notSetUp
        case .notFound: return DS.Symbol.notFound
        }
    }

    @ViewBuilder private var buttons: some View {
        ForEach(Self.actionTitles(kind), id: \.self) { title in
            Button(title, action: action(for: title)).controlSize(DS.Control.form)
        }
    }

    private func action(for title: String) -> @MainActor @Sendable () -> Void {
        switch title {
        case "Show All Projects": return actions.showAll
        case "Try Again": return actions.tryAgain
        case "Queue Settings…": return actions.settings
        case "Set Up…": return actions.setUp
        case "Back to Queue": return actions.backToQueue
        case "Show Closed Ask": return actions.showClosed
        default: return {}
        }
    }

    public static func title(_ kind: StateKind) -> String {
        switch kind {
        case .loading: return "Loading asks"
        case .empty: return "Nothing waiting"
        case .emptyFiltered(let project, _): return "Nothing waiting in " + SectionHeader.displayName(project)
        case .offline(let title, _): return title
        case .notSetUp: return "No queue set up"
        case .notFound: return "This ask is no longer open"
        }
    }

    /// `reason` arrives through UserFacingError.text, already one revealed line. `source` is the
    /// raw source name ("Pond" / "This Mac"), as the panel passes it.
    public static func description(_ kind: StateKind) -> String {
        switch kind {
        case let .loading(source, stillTrying): return stillTrying ? "Still trying…" : "From " + source
        case .empty(let updated), .emptyFiltered(_, let updated): return "Updated \(updated)"
        case .offline(_, let reason): return reason
        case .notSetUp: return "Choose where asks come from."
        case .notFound: return "It was closed or removed."
        }
    }

    public static func actionTitles(_ kind: StateKind) -> [String] {
        switch kind {
        case .loading(_, let stillTrying): return stillTrying ? ["Queue Settings…"] : []
        case .empty: return []
        case .emptyFiltered: return ["Show All Projects"]
        case .offline: return ["Try Again", "Queue Settings…"]
        case .notSetUp: return ["Set Up…"]
        case .notFound(let canShowClosed): return canShowClosed ? ["Back to Queue", "Show Closed Ask"] : ["Back to Queue"]
        }
    }
}
