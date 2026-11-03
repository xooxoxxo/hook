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

/// Report a Problem on a step (0.12, pick 3 B): what DetailSteps hands the step rows. Each
/// row reads its own slot (`stepReport`); a parent hands its sub-steps theirs from the map.
public struct StepReports: Sendable {
    /// The ask takes reports: open, from a Pond, never This Mac.
    public var allowed: Bool
    /// The paths of steps a report can be about (`ProblemReport.actionable`).
    public var actionable: Set<String>
    /// The paths with a report waiting for a correction.
    public var reported: Set<String>
    /// The step the docked composer is open on.
    public var target: String?
    public var onReport: @MainActor @Sendable (String) -> Void

    public init(allowed: Bool, actionable: Set<String>, reported: Set<String>, target: String?,
                onReport: @escaping @MainActor @Sendable (String) -> Void) {
        self.allowed = allowed
        self.actionable = actionable
        self.reported = reported
        self.target = target
        self.onReport = onReport
    }

    public static let none = StepReports(allowed: false, actionable: [], reported: [], target: nil, onReport: { _ in })

    public func slot(_ path: String) -> StepReportSlot {
        let onReport = onReport
        return StepReportSlot(allowed: allowed, actionable: actionable.contains(path), reported: reported.contains(path),
                              targeted: target == path, onReport: { onReport(path) })
    }
}

/// One row's part of `StepReports`.
public struct StepReportSlot: Sendable {
    public var allowed: Bool
    public var actionable: Bool
    public var reported: Bool
    public var targeted: Bool
    public var onReport: @MainActor @Sendable () -> Void
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
    func askTextSelection() -> some View { modifier(AskTextSelection()) }
}

/// The lock's rules for the view inputs; static so tests can pin them.
public enum AskContentLock {
    public static func allowsSelection(locked: Bool) -> Bool { !locked }
    public static func allowsCopy(locked: Bool) -> Bool { !locked }
    /// Opening a link or file, answering, and the step's own actions.
    public static func allowsActions(locked: Bool) -> Bool { !locked }
}
