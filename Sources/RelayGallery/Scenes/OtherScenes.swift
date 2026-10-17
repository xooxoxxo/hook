import AppKit
import RelayCore
import RelayUI
import SwiftUI

/// Six menu-bar cells, 48 × 24 pt each, on the window background: none, 1, 9,
/// dot (12 asks), offline (disabled symbol, badge 0.5), away (disabled symbol, full badge).
final class BadgeStrip: NSView {
    static let cell = NSSize(width: 48, height: 24)
    static let states: [(MenuBarState)] = [
        MenuBarState(count: 0), MenuBarState(count: 1), MenuBarState(count: 9), MenuBarState(count: 12),
        MenuBarState(count: 5, reachable: false), MenuBarState(count: 5, away: true),
    ]

    override init(frame: NSRect) {
        super.init(frame: frame)
        for (index, state) in Self.states.enumerated() {
            let cell = NSView(frame: NSRect(x: CGFloat(index) * Self.cell.width, y: 0,
                                            width: Self.cell.width, height: Self.cell.height))
            let symbol = NSImage(systemSymbolName: DS.Symbol.menuBar, accessibilityDescription: "Relay")
            symbol?.isTemplate = true
            let imageView = NSImageView(image: symbol ?? NSImage())
            imageView.contentTintColor = .labelColor
            let size = symbol?.size ?? NSSize(width: 16, height: 16)
            imageView.frame = NSRect(x: (Self.cell.width - size.width) / 2, y: (Self.cell.height - size.height) / 2,
                                     width: size.width, height: size.height)
            imageView.alphaValue = state.symbolDimmed ? 0.5 : 1
            cell.addSubview(imageView)
            let badge = BadgeView(frame: .zero)
            badge.badge = state.badge
            badge.dimmed = state.dimmed
            badge.frame = BadgeGeometry.frame(for: state.badge, in: cell.bounds, imageRect: imageView.frame, flipped: false)
            cell.addSubview(badge)
            addSubview(cell)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("BadgeStrip is created in code") }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
    }
}

@MainActor let otherScenes: [GalleryScene] = [
    GalleryScene(
        name: "menubar-badges",
        size: .appKit(NSSize(width: BadgeStrip.cell.width * CGFloat(BadgeStrip.states.count), height: BadgeStrip.cell.height)),
        standIn: false,
        view: { AnyView(EmptyView()) },
        appKit: { BadgeStrip(frame: .zero) }),
]
