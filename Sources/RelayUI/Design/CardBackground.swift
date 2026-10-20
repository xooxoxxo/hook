import AppKit
import SwiftUI

/// Design/CardBackground: a queue card, drawn as the List row's background. It fills the row
/// less half the card gap above and below and `cardEdge` at the sides, so neighbouring cards
/// stand apart. The card draws the selection itself (an accent tint under an accent border),
/// so the List's own highlight is switched off on its table view (`ListHighlightOff`, once
/// per List). A `quiet` card (recently closed) has the fainter fill and its own hairline.
public struct CardBackground: View, Equatable {
    let selected: Bool
    let quiet: Bool
    @Environment(\.colorSchemeContrast) private var contrast

    public init(selected: Bool, quiet: Bool = false) {
        self.selected = selected
        self.quiet = quiet
    }

    nonisolated public static func == (a: CardBackground, b: CardBackground) -> Bool {
        a.selected == b.selected && a.quiet == b.quiet
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: DS.Metric.cardRadius, style: .continuous)
        shape
            .fill(quiet ? DS.Color.cardFillQuiet : DS.Color.cardFill)
            .overlay {
                if selected { shape.fill(DS.Color.cardSelectedFill) }
            }
            .overlay {
                if selected {
                    shape.strokeBorder(DS.Color.cardSelectedStroke, lineWidth: DS.Metric.cardSelectedBorder)
                } else if contrast == .increased {
                    shape.strokeBorder(DS.Color.cardStrokeContrast, lineWidth: DS.Metric.cardBorderContrast)
                } else {
                    shape.strokeBorder(quiet ? DS.Color.cardStrokeQuiet : DS.Color.cardStroke, lineWidth: DS.Metric.cardBorder)
                }
            }
            .alignmentProbe(.cardEdge, measure: .frame)
            .padding(.vertical, DS.Space.cardGap / 2)
            .padding(.horizontal, DS.Space.cardEdge)
            .accessibilityHidden(true)
    }
}

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
