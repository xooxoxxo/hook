import AppKit

/// A panel whose first click acts, while another app has focus or the panel just isn't key.
///
/// AppKit asks the deepest view under the pointer whether it accepts the first mouse, and
/// drops the click (it only makes the window key) when that view says no. Inside the queue
/// that view is the private hosting view SwiftUI's List makes for each row, which says no,
/// so a click on a row only focused the panel. The panel becomes key
/// before AppKit sees the press instead, so no view is asked and every control, row and
/// gesture gets the click. A non-activating panel still leaves the frontmost app active.
open class FirstClickPanel: NSPanel {
    open override func sendEvent(_ event: NSEvent) {
        if FirstClick.makesKeyFirst(event.type, isKey: isKeyWindow, canBecomeKey: canBecomeKey,
                                    sheetOpen: attachedSheet != nil) {
            makeKey()
        }
        super.sendEvent(event)
    }
}

/// When `FirstClickPanel` makes itself key before a press reaches its views.
public enum FirstClick {
    /// A left press on a panel that isn't key yet and can be. A sheet on the panel takes
    /// its clicks itself, so the panel is left alone then.
    public static func makesKeyFirst(_ type: NSEvent.EventType, isKey: Bool, canBecomeKey: Bool,
                                     sheetOpen: Bool) -> Bool {
        type == .leftMouseDown && !isKey && canBecomeKey && !sheetOpen
    }
}
