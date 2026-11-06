import AppKit
import SwiftUI
import RelayUI

/// Turns off the stock selection highlight of the table view behind the List it is the
/// background of. Selection, keyboard navigation and the context menu are untouched; only
/// the drawing goes. One per List: it finds the table once (the List's table sits beside
/// it, under a shared ancestor) and watches its highlight style, so a reset by SwiftUI is
/// undone straight away. No row carries an AppKit view or walks the view tree for this.
struct ListHighlightOff: NSViewRepresentable {
    final class Probe: NSView {
        private weak var table: NSTableView?
        private var observation: NSKeyValueObservation?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
            // The List's table may join the window just after its background does.
            if table == nil { DispatchQueue.main.async { [weak self] in self?.apply() } }
        }

        /// The List and its background are sized and laid out together, so by then its table is in place.
        override func layout() {
            super.layout()
            if table?.window == nil { apply() }
        }

        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            if table?.window == nil { apply() }
        }

        func apply() {
            if table?.window == nil { attach(findTable()) }
            if let table, table.selectionHighlightStyle != .none { table.selectionHighlightStyle = .none }
        }

        private func attach(_ found: NSTableView?) {
            guard found !== table else { return }
            observation = nil
            table = found
            observation = found?.observe(\.selectionHighlightStyle, options: [.new]) { table, _ in
                MainActor.assumeIsolated {
                    if table.selectionHighlightStyle != .none { table.selectionHighlightStyle = .none }
                }
            }
        }

        /// The List's table: the one, under the nearest ancestor that has it, whose scroll
        /// view sits where this background does (a window may hold several Lists).
        private func findTable() -> NSTableView? {
            guard bounds.width > 0, bounds.height > 0 else { return nil }
            let center = convert(NSPoint(x: bounds.midX, y: bounds.midY), to: nil)
            var ancestor = superview
            while let current = ancestor {
                let match = Self.tables(in: current).first { table in
                    let frame = table.enclosingScrollView ?? table
                    return frame.convert(frame.bounds, to: nil).contains(center)
                }
                if let match { return match }
                ancestor = current.superview
            }
            return nil
        }

        private static func tables(in view: NSView) -> [NSTableView] {
            if let table = view as? NSTableView { return [table] }
            return view.subviews.flatMap { tables(in: $0) }
        }
    }

    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ view: Probe, context: Context) { view.apply() }
}

extension View {
    /// For a List whose rows use CardBackground: switches the table's own highlight off.
    public func cardListHighlightOff() -> some View {
        background(ListHighlightOff())
    }
}
