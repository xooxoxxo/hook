import AppKit
import SwiftUI

/// A click on the visible panel acts on its control even when another app has focus.
/// This also supports macOS 14, before SwiftUI's window-activation modifier.
public final class PanelHostingView<Content: View>: NSHostingView<Content> {
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
