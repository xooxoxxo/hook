import CoreGraphics
import Foundation

/// What the global shortcut or a left click on the menu-bar icon does to the panel (§4.1).
public enum ToggleAction: Equatable, Sendable {
    case showAndFocus
    case focus
    case redockAndFocus
    case hide
}

/// The show / hide / toggle rule. Pure: the panel passes its state in. The refresh
/// on show is `Store.refreshIfStale()`.
public enum PanelToggle {
    /// A frame within this many points of the target counts as docked.
    public static let dockTolerance: CGFloat = 0.5

    /// hidden → show with focus; visible but off its docked frame → re-dock and focus
    /// (never hide); visible without focus → focus; focused and docked → hide.
    public static func decide(visible: Bool, isKey: Bool, frame: CGRect, target: CGRect) -> ToggleAction {
        guard visible else { return .showAndFocus }
        guard isDocked(frame, at: target) else { return .redockAndFocus }
        return isKey ? .hide : .focus
    }

    public static func isDocked(_ frame: CGRect, at target: CGRect) -> Bool {
        [frame.minX - target.minX, frame.minY - target.minY,
         frame.width - target.width, frame.height - target.height]
            .allSatisfy { abs($0) <= dockTolerance }
    }
}
