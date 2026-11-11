import Foundation
import RelayCore
import SwiftUI

/// Where the file rows of one ask stand: is the ask from this Mac, and what the buttons do.
/// DetailView sets it for its subtree; rows never look up the host themselves.
public struct FileRowContext: Sendable {
    public var place: FilePlace
    public var actions: FileActions
    public var copy: @MainActor @Sendable (String) -> Void
    public var home: String
    /// The ask's content was locked when the row rendered (a correction is unreviewed): the
    /// row's buttons and menu items are disabled.
    public var contentLocked: Bool
    /// The Store's stamp-bound check for the ask (`allowsFileAction`, bound to the revision the
    /// detail rendered), given the path as sent: asked at the moment each action acts, so a
    /// correction that lands after the render refuses it. Outside an ask (the gallery) it allows.
    public var allows: @MainActor @Sendable (String) -> Bool

    public init(place: FilePlace = .here, actions: FileActions = .none,
                copy: (@MainActor @Sendable (String) -> Void)? = nil,
                home: String = NSHomeDirectory(), contentLocked: Bool = false,
                allows: @escaping @MainActor @Sendable (String) -> Bool = { _ in true }) {
        self.place = place
        self.actions = actions
        self.copy = copy ?? { PlatformClipboard.copy($0) }
        self.home = home
        self.contentLocked = contentLocked
        self.allows = allows
    }

    /// Whether the row's buttons and menu items do anything, as rendered.
    public var actionsEnabled: Bool { AskContentLock.allowsActions(locked: contentLocked) }

    /// The rendered lock and the Store's check now: both must let `link` act.
    @MainActor private func permits(_ link: FileLink) -> Bool { actionsEnabled && allows(link.raw) }

    /// Runs `command` on `link`, whose row shows `state`. The Store's check runs before the
    /// file check and again right before the act, so a correction that lands between the
    /// render and the click, or during the check, refuses it (`.refused`, nothing runs).
    @MainActor public func perform(_ command: FileRowCommand, on link: FileLink, state: FileRowState) async -> FileRowResult {
        guard permits(link) else { return FileRowResult(outcome: .refused) }
        if command == .copyPath {
            // From another machine, "~" means that machine's home: the path goes as sent.
            if case .otherMac = state { copy(link.raw) } else { copy(link.path) }
            HookLog.action(.copy)
            return FileRowResult(outcome: .done)
        }
        let found = await actions.check(link.path)
        guard permits(link) else { return FileRowResult(outcome: .refused) }
        switch (command, found) {
        case (.open, .document(let file)): actions.open(file)
        case (.openWith(let app), .document(let file)): actions.openWith(file, app)
        case (.openWithOther, .document(let file)): actions.openWithOther(file)
        case (.reveal, .document(let file)): actions.reveal(file.url)
        case (.reveal, .refused(let url)): actions.reveal(url)
        default: return FileRowResult(outcome: .unavailable, check: found)
        }
        HookLog.action(.open)
        return FileRowResult(outcome: .done, check: found)
    }
}

/// What a file row's click asks for.
public enum FileRowCommand: Equatable, Sendable {
    case open, openWith(URL), openWithOther, reveal, copyPath
}

/// What a file row's click did, and what its file check found (nil when it didn't check).
public struct FileRowResult: Equatable, Sendable {
    public enum Outcome: Equatable, Sendable {
        /// The action ran.
        case done
        /// The ask is locked, or changed since the row rendered: nothing ran.
        case refused
        /// The check found no document (or nothing to reveal): nothing ran.
        case unavailable
    }

    public var outcome: Outcome
    public var check: FileCheck?

    public init(outcome: Outcome, check: FileCheck? = nil) {
        self.outcome = outcome
        self.check = check
    }
}

private struct FileRowContextKey: EnvironmentKey {
    static let defaultValue = FileRowContext()
}

extension EnvironmentValues {
    public var fileRowContext: FileRowContext {
        get { self[FileRowContextKey.self] }
        set { self[FileRowContextKey.self] = newValue }
    }
}
