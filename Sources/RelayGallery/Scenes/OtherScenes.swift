import AppKit
import RelayCore
import RelayUI
import SwiftUI

/// Five menu-bar cells, 48 × 24 pt each, on the window background: nothing waiting,
/// asks all seen (no dot), an unseen ask (dot), offline (disabled symbol, dot 0.5),
/// away (disabled symbol, full dot).
final class BadgeStrip: NSView {
    static let cell = NSSize(width: 48, height: 24)
    static let states: [(MenuBarState)] = [
        MenuBarState(count: 0), MenuBarState(count: 3), MenuBarState(count: 3, unseen: true),
        MenuBarState(count: 5, reachable: false, unseen: true), MenuBarState(count: 5, unseen: true, away: true),
    ]

    override init(frame: NSRect) {
        super.init(frame: frame)
        for (index, state) in Self.states.enumerated() {
            let cell = NSView(frame: NSRect(x: CGFloat(index) * Self.cell.width, y: 0,
                                            width: Self.cell.width, height: Self.cell.height))
            let symbol = NSImage(systemSymbolName: DS.Symbol.menuBar, accessibilityDescription: "Hook")
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
    GalleryScene(name: "welcome-1", size: .wide(width: DS.Metric.welcomeWidth, height: nil), standIn: false, rules: [],
                 view: { welcomeWindow(WelcomeView(model: FixtureSettingsModel(settings: SettingsFixtures.snapshot(config: nil)),
                                             onDone: {}, onQuit: {})) }, appKit: nil),
    GalleryScene(name: "welcome-1-mailbox-error", size: .wide(width: DS.Metric.welcomeWidth, height: nil), standIn: false,
                 rules: [.sameLeading(.mailboxField, tolerance: 1)],
                 view: {
                     var flow = WelcomeFlow()
                     flow.startTapped(isMailbox: true)
                     flow.firstList(ok: false, reason: "unauthorized")
                     return welcomeWindow(WelcomeView(
                         model: FixtureSettingsModel(
                             settings: SettingsFixtures.snapshot(config: RelayConfig(mailboxURL: "https://mailbox.example:8790")),
                             draft: MailboxDraft(address: "https://mailbox.example:8790", tokenFile: "~/.config/relay/mailbox-token")),
                         initialFlow: flow, onDone: {}, onQuit: {}))
                 }, appKit: nil),
    GalleryScene(name: "welcome-2", size: .wide(width: DS.Metric.welcomeWidth, height: nil), standIn: false, rules: [],
                 view: {
                     var flow = WelcomeFlow()
                     flow.startTapped(isMailbox: false)
                     return welcomeWindow(WelcomeView(model: FixtureSettingsModel(settings: SettingsFixtures.snapshot(permission: .notDetermined)),
                                                initialFlow: flow, onDone: {}, onQuit: {}))
                 }, appKit: nil),
]

/// The window background the real Welcome window paints behind its title and buttons;
/// offscreen, only the grouped Form paints its own.
@MainActor private func welcomeWindow(_ view: some View) -> AnyView {
    AnyView(view.background(DS.Color.panelStandInOpaque))
}
