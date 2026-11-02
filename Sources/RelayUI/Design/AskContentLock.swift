import SwiftUI

/// The review lock (`DetailSnapshot.locked`): while a correction is unreviewed, or the ask's
/// history changed, nothing ask-supplied can be selected, copied or opened. DetailView sets it
/// for its subtree. It is not the blocking-step lock (`StepView`'s `locked`), which keeps its meaning.
private struct AskContentLockedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    public var askContentLocked: Bool {
        get { self[AskContentLockedKey.self] }
        set { self[AskContentLockedKey.self] = newValue }
    }
}

/// `.textSelection(.enabled)`, or `.disabled` while the ask's content is locked, so ⌘C on
/// selected text can't copy what the owner hasn't reviewed.
struct AskTextSelection: ViewModifier {
    @Environment(\.askContentLocked) private var locked

    @ViewBuilder func body(content: Content) -> some View {
        if AskContentLock.allowsSelection(locked: locked) {
            content.textSelection(.enabled)
        } else {
            content.textSelection(.disabled)
        }
    }
}

extension View {
    /// Ask-supplied text: selectable unless the ask's content is locked.
    func askTextSelection() -> some View { modifier(AskTextSelection()) }
}

/// The lock's rules for the view inputs; static so tests can pin them.
public enum AskContentLock {
    public static func allowsSelection(locked: Bool) -> Bool { !locked }
    public static func allowsCopy(locked: Bool) -> Bool { !locked }
    /// Opening a link or file, answering, and the step's own actions.
    public static func allowsActions(locked: Bool) -> Bool { !locked }
}
