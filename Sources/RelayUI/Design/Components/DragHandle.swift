import AppKit
import RelayCore
import SwiftUI

/// What the panel does with a header drag; the app supplies it, the gallery leaves `.none`.
public struct PanelDragActions: Sendable {
    public var began: @MainActor @Sendable () -> Void
    public var moved: @MainActor @Sendable (CGSize) -> Void
    public var ended: @MainActor @Sendable (CGPoint) -> Void
    public var doubleClicked: @MainActor @Sendable () -> Void

    public init(began: @escaping @MainActor @Sendable () -> Void,
                moved: @escaping @MainActor @Sendable (CGSize) -> Void,
                ended: @escaping @MainActor @Sendable (CGPoint) -> Void,
                doubleClicked: @escaping @MainActor @Sendable () -> Void) {
        self.began = began
        self.moved = moved
        self.ended = ended
        self.doubleClicked = doubleClicked
    }

    public static let none = PanelDragActions(began: {}, moved: { _ in }, ended: { _ in }, doubleClicked: {})
}

private struct PanelDragActionsKey: EnvironmentKey {
    static let defaultValue = PanelDragActions.none
}

extension EnvironmentValues {
    public var panelDragActions: PanelDragActions {
        get { self[PanelDragActionsKey.self] }
        set { self[PanelDragActionsKey.self] = newValue }
    }
}

/// Sits behind the header content: open hand over empty header space, closed hand
/// while dragging. Pointer positions are screen points (`NSEvent.mouseLocation`).
public final class DragHandleView: NSView {
    var actions = PanelDragActions.none
    private var tracker = DragTracker(threshold: DS.Metric.dragThreshold)

    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    public override var mouseDownCanMoveWindow: Bool { false }
    public override func isAccessibilityElement() -> Bool { false }

    public override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    public override func mouseDown(with event: NSEvent) {
        if tracker.mouseDown(at: NSEvent.mouseLocation, clickCount: event.clickCount) == .doubleClick {
            actions.doubleClicked()
        }
    }

    public override func mouseDragged(with event: NSEvent) {
        let point = NSEvent.mouseLocation
        switch tracker.mouseDragged(to: point) {
        case .began?:
            actions.began()
            NSCursor.closedHand.set()
            if case .moved(let delta)? = tracker.mouseDragged(to: point) { actions.moved(delta) }
        case .moved(let delta)?:
            actions.moved(delta)
        default:
            break
        }
    }

    public override func mouseUp(with event: NSEvent) {
        if case .ended(let point)? = tracker.mouseUp(at: NSEvent.mouseLocation) {
            actions.ended(point)
        }
        window?.invalidateCursorRects(for: self)
    }

    public override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        tracker.cancel()
    }
}

/// The header's drag surface. VoiceOver skips it; the header's custom actions
/// ("Dock on the left edge" / "Dock on the right edge") replace the drag.
public struct DragHandle: NSViewRepresentable {
    public init() {}

    public func makeNSView(context: Context) -> DragHandleView {
        let view = DragHandleView()
        view.actions = context.environment.panelDragActions
        return view
    }

    public func updateNSView(_ view: DragHandleView, context: Context) {
        view.actions = context.environment.panelDragActions
    }
}
