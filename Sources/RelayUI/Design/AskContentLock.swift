import RelayCore
import SwiftUI

/// The review lock (`DetailSnapshot.locked`): while a correction is unreviewed, or the ask's
/// history changed, nothing ask-supplied can be selected, copied or opened. DetailView sets it
/// for its subtree. It is not the blocking-step lock (`StepView`'s `locked`), which keeps its meaning.
private struct AskContentLockedKey: EnvironmentKey {
    static let defaultValue = false
}

/// A corrected ask's step tags by path ("Changed", "New", "Removed"): DetailSteps sets the map,
/// and each row its own `stepTag`, so StepView and ParentStepView draw it beside their title.
private struct StepTagsKey: EnvironmentKey {
    static let defaultValue: [String: StepChip] = [:]
}

private struct StepTagKey: EnvironmentKey {
    static let defaultValue: StepChip? = nil
}

/// Report a Problem on a step (0.14, owner pick 1): what DetailSteps hands the step rows. Each
/// row reads its own slot (`stepReport`); a parent hands its sub-steps theirs from the map. The
/// targeted row draws the inline field, with the send state, the key, the caps and the draft.
public struct StepReports: Sendable {
    /// The ask takes reports: open, from a Pond, never This Mac.
    public var allowed: Bool
    /// The paths of steps a report can be about (`ProblemReport.actionable`).
    public var actionable: Set<String>
    /// The paths with a report waiting for a correction.
    public var reported: Set<String>
    /// The step whose inline field is open.
    public var target: String?
    /// The open field's send state.
    public var state: ReportBoxState
    /// This Mac has an approved owner key (read only while a field is open).
    public var keyReady: Bool
    public var limits: TalkLimits
    /// The open field's text.
    public var draft: String
    public var onReport: @MainActor @Sendable (String) -> Void
    public var onSend: @MainActor @Sendable (String) -> Void
    public var onCancel: @MainActor @Sendable () -> Void
    public var onEdit: @MainActor @Sendable (String) -> Void
    /// The open field took or lost the keys (⌘Return sends while it has them).
    public var onFocus: @MainActor @Sendable (Bool) -> Void

    public init(allowed: Bool, actionable: Set<String>, reported: Set<String>, target: String?,
                state: ReportBoxState = .idle, keyReady: Bool = false, limits: TalkLimits = .old, draft: String = "",
                onReport: @escaping @MainActor @Sendable (String) -> Void,
                onSend: @escaping @MainActor @Sendable (String) -> Void = { _ in },
                onCancel: @escaping @MainActor @Sendable () -> Void = {},
                onEdit: @escaping @MainActor @Sendable (String) -> Void = { _ in },
                onFocus: @escaping @MainActor @Sendable (Bool) -> Void = { _ in }) {
        self.allowed = allowed
        self.actionable = actionable
        self.reported = reported
        self.target = target
        self.state = state
        self.keyReady = keyReady
        self.limits = limits
        self.draft = draft
        self.onReport = onReport
        self.onSend = onSend
        self.onCancel = onCancel
        self.onEdit = onEdit
        self.onFocus = onFocus
    }

    public static let none = StepReports(allowed: false, actionable: [], reported: [], target: nil, onReport: { _ in })

    public func slot(_ path: String) -> StepReportSlot {
        let onReport = onReport, targeted = target == path
        return StepReportSlot(allowed: allowed, actionable: actionable.contains(path), reported: reported.contains(path),
                              targeted: targeted, fieldOpen: target != nil, state: targeted ? state : .idle,
                              keyReady: keyReady, limits: limits,
                              draft: targeted ? draft : "", onReport: { onReport(path) }, onSend: onSend,
                              onCancel: onCancel, onEdit: onEdit, onFocus: onFocus)
    }
}

/// One row's part of `StepReports`.
public struct StepReportSlot: Sendable {
    public var allowed: Bool
    public var actionable: Bool
    public var reported: Bool
    /// The inline field is open on this row.
    public var targeted: Bool
    /// A field is open somewhere in the ask (this row or another): no row offers Report then.
    public var fieldOpen: Bool
    public var state: ReportBoxState
    public var keyReady: Bool
    public var limits: TalkLimits
    public var draft: String
    public var onReport: @MainActor @Sendable () -> Void
    public var onSend: @MainActor @Sendable (String) -> Void
    public var onCancel: @MainActor @Sendable () -> Void
    public var onEdit: @MainActor @Sendable (String) -> Void
    public var onFocus: @MainActor @Sendable (Bool) -> Void

    public init(allowed: Bool, actionable: Bool, reported: Bool, targeted: Bool, fieldOpen: Bool = false,
                state: ReportBoxState, keyReady: Bool, limits: TalkLimits, draft: String = "",
                onReport: @escaping @MainActor @Sendable () -> Void = {},
                onSend: @escaping @MainActor @Sendable (String) -> Void = { _ in },
                onCancel: @escaping @MainActor @Sendable () -> Void = {},
                onEdit: @escaping @MainActor @Sendable (String) -> Void = { _ in },
                onFocus: @escaping @MainActor @Sendable (Bool) -> Void = { _ in }) {
        self.allowed = allowed
        self.actionable = actionable
        self.reported = reported
        self.targeted = targeted
        self.fieldOpen = fieldOpen || targeted
        self.state = state
        self.keyReady = keyReady
        self.limits = limits
        self.draft = draft
        self.onReport = onReport
        self.onSend = onSend
        self.onCancel = onCancel
        self.onEdit = onEdit
        self.onFocus = onFocus
    }
}

private struct StepReportsKey: EnvironmentKey {
    static let defaultValue = StepReports.none
}

private struct StepReportKey: EnvironmentKey {
    static let defaultValue: StepReportSlot? = nil
}

extension EnvironmentValues {
    public var stepReports: StepReports {
        get { self[StepReportsKey.self] }
        set { self[StepReportsKey.self] = newValue }
    }

    public var stepReport: StepReportSlot? {
        get { self[StepReportKey.self] }
        set { self[StepReportKey.self] = newValue }
    }

    public var askContentLocked: Bool {
        get { self[AskContentLockedKey.self] }
        set { self[AskContentLockedKey.self] = newValue }
    }

    public var stepTags: [String: StepChip] {
        get { self[StepTagsKey.self] }
        set { self[StepTagsKey.self] = newValue }
    }

    public var stepTag: StepChip? {
        get { self[StepTagKey.self] }
        set { self[StepTagKey.self] = newValue }
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
    public func askTextSelection() -> some View { modifier(AskTextSelection()) }
}

/// The lock's rules for the view inputs; static so tests can pin them.
public enum AskContentLock {
    public static func allowsSelection(locked: Bool) -> Bool { !locked }
    public static func allowsCopy(locked: Bool) -> Bool { !locked }
    /// Opening a link or file, answering, and the step's own actions.
    public static func allowsActions(locked: Bool) -> Bool { !locked }
}
