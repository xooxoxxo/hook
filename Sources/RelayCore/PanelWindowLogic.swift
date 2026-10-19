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

/// The slide-in for a "now" ask (§4.11). Pure: the panel animates the frames.
public enum SlideIn {
    /// Just beyond the docked frame's screen edge, so the slide covers the panel's width.
    public static func offscreenFrame(docked: CGRect, edge: SidebarEdge) -> CGRect {
        let dx = edge == .left ? -docked.width : docked.width
        return docked.offsetBy(dx: dx, dy: 0)
    }

    /// Home, "Slide the panel in" on, and the panel hidden. A visible panel never moves.
    public static func shouldSlide(home: Bool, slideInOn: Bool, panelVisible: Bool) -> Bool {
        home && slideInOn && !panelVisible
    }

    /// The VoiceOver announcement when a "now" ask arrives while the panel is up.
    public static func announcement(title: String, project: String, outsideFilter: Bool) -> String {
        let title = Sanitize.revealLine(title)
        guard outsideFilter else { return "New Now ask: \(title)" }
        return "New Now ask in \(Sanitize.revealLine(project)): \(title)"
    }
}
