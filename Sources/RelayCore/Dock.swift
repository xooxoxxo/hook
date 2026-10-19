import CoreGraphics

/// One display as docking sees it, in AppKit screen coordinates (origin at the
/// bottom left of the primary display, y up).
public struct DockScreen: Sendable, Equatable {
    /// The display's UUID string, stable across reconnects and rearranging.
    public var id: String
    public var frame: CGRect
    /// `frame` minus the menu bar and the Dock.
    public var visibleFrame: CGRect
    /// The display with the menu bar (`NSScreen.screens.first`).
    public var isPrimary: Bool

    public init(id: String, frame: CGRect, visibleFrame: CGRect, isPrimary: Bool) {
        self.id = id
        self.frame = frame
        self.visibleFrame = visibleFrame
        self.isPrimary = isPrimary
    }
}

/// Where the sidebar goes: which display, which frame, and where a drag lands.
public enum DockGeometry {
    /// The pinned display when it's connected; else the primary one; else the
    /// first; nil with no displays. A missing pinned display isn't forgotten:
    /// the caller keeps `pinned`, so the panel returns when it reconnects.
    public static func target(screens: [DockScreen], pinned: String?) -> DockScreen? {
        if let pinned, let screen = screens.first(where: { $0.id == pinned }) { return screen }
        return screens.first(where: \.isPrimary) ?? screens.first
    }

    /// Full height of `visibleFrame`, `width` wide, flush to `edge`.
    public static func frame(edge: SidebarEdge, on screen: DockScreen, width: CGFloat) -> CGRect {
        let visible = screen.visibleFrame
        let x = edge == .left ? visible.minX : visible.maxX - width
        return CGRect(x: x, y: visible.minY, width: width, height: visible.height)
    }

    /// Where a drag released at `point` pins the panel: the display whose frame
    /// holds the point (else the nearest one), and the half of it the point is in.
    public static func snap(point: CGPoint, screens: [DockScreen]) -> (screenID: String, edge: SidebarEdge)? {
        let screen = screens.first(where: { $0.frame.contains(point) })
            ?? screens.min(by: { distance(point, $0.frame) < distance(point, $1.frame) })
        guard let screen else { return nil }
        return (screen.id, point.x < screen.frame.midX ? .left : .right)
    }

    /// Distance from `point` to the nearest point of `rect`; 0 inside it.
    static func distance(_ point: CGPoint, _ rect: CGRect) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return (dx * dx + dy * dy).squareRoot()
    }
}

/// What one pointer event on the panel header means.
public enum DragEvent: Equatable, Sendable { case began, moved(CGSize), ended(CGPoint), click, doubleClick }

/// The header's press-drag-release logic, in screen points. Under `threshold`
/// of travel a press is a click; past it the panel follows the pointer.
public struct DragTracker: Sendable {
    public let threshold: CGFloat
    private var start: CGPoint?
    private var dragging = false

    public init(threshold: CGFloat) {
        self.threshold = threshold
    }

    public mutating func mouseDown(at point: CGPoint, clickCount: Int) -> DragEvent? {
        dragging = false
        if clickCount >= 2 {
            start = nil
            return .doubleClick
        }
        start = point
        return nil
    }

    /// `.began` once, when the travel first reaches `threshold`; every later call `.moved`
    /// with the offset from the press. Call again after `.began` to get the first `.moved`.
    public mutating func mouseDragged(to point: CGPoint) -> DragEvent? {
        guard let start else { return nil }
        let delta = CGSize(width: point.x - start.x, height: point.y - start.y)
        if !dragging {
            guard max(abs(delta.width), abs(delta.height)) >= threshold else { return nil }
            dragging = true
            return .began
        }
        return .moved(delta)
    }

    public mutating func mouseUp(at point: CGPoint) -> DragEvent? {
        defer { cancel() }
        guard start != nil else { return nil }
        return dragging ? .ended(point) : .click
    }

    /// Drops the press (the view left its window, or the panel was hidden).
    public mutating func cancel() {
        start = nil
        dragging = false
    }
}

extension DockGeometry {
    /// A config change docks the panel only when it moves it: the edge or the pinned
    /// display. A missing config means the defaults (right edge, main display).
    public static func needsDock(old: RelayConfig?, new: RelayConfig?) -> Bool {
        (old?.sidebarEdge ?? .right) != (new?.sidebarEdge ?? .right)
            || old?.sidebarDisplay != new?.sidebarDisplay
    }

    /// Where the panel sits mid-drag: the frame at drag start moved by the pointer's
    /// travel, at its docked size (it never resizes until the snap).
    public static func dragFrame(start: CGRect, delta: CGSize) -> CGRect {
        CGRect(x: start.minX + delta.width, y: start.minY + delta.height, width: start.width, height: start.height)
    }

    /// The display the panel is on: the one holding its centre, else the one it overlaps
    /// most, else nil. ⌃⌘← / ⌃⌘→ dock on this display.
    public static func currentScreenID(frame: CGRect, screens: [DockScreen]) -> String? {
        let centre = CGPoint(x: frame.midX, y: frame.midY)
        if let screen = screens.first(where: { $0.frame.contains(centre) }) { return screen.id }
        let overlaps = screens.map { screen -> (String, CGFloat) in
            let common = screen.frame.intersection(frame)
            return (screen.id, common.isNull ? 0 : common.width * common.height)
        }
        guard let best = overlaps.max(by: { $0.1 < $1.1 }), best.1 > 0 else { return nil }
        return best.0
    }
}
