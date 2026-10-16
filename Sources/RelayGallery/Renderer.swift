import AppKit
import RelayCore
import RelayUI
import SwiftUI

/// Draws as key and main offscreen. These private-selector overrides exist only
/// in RelayGallery; never copy them into Relay.
final class KeyWindow: NSWindow {
    override var isKeyWindow: Bool { true }
    override var isMainWindow: Bool { true }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    @objc(_hasActiveAppearance) func hasActiveAppearance() -> Bool { true }
    @objc(_hasActiveAppearanceIgnoringKeyFocus) func hasActiveAppearanceIgnoringKeyFocus() -> Bool { true }
    @objc(_hasKeyAppearance) func hasKeyAppearancePrivate() -> Bool { true }
    @objc(hasKeyAppearance) func hasKeyAppearance() -> Bool { true }
    @objc(hasMainAppearance) func hasMainAppearance() -> Bool { true }
}

/// Reports itself active so controls draw in their active state; never activated.
final class PreviewApp: NSApplication {
    override var isActive: Bool { true }
}

struct RenderResult {
    let files: [String]
}

@MainActor let themes: [(name: String, appearance: NSAppearance.Name)] = [("light", .aqua), ("dark", .darkAqua)]

/// Every table view under `view`, depth first.
@MainActor func tables(_ view: NSView) -> [NSTableView] {
    var out: [NSTableView] = []
    if let table = view as? NSTableView { out.append(table) }
    for sub in view.subviews { out += tables(sub) }
    return out
}

/// The environment every captured SwiftUI root gets, from the command-line flags.
@MainActor func decorated(_ view: AnyView, options: GalleryOptions, standIn: Bool) -> AnyView {
    var root = AnyView(view.environment(\.appearsActive, true))
    if options.contrast { root = AnyView(root.environment(\._colorSchemeContrast, .increased)) }
    if options.reduceTransparency { root = AnyView(root.environment(\._accessibilityReduceTransparency, true)) }
    if options.xl {
        // .dynamicTypeSize is kept as spec §3.5 asks, but it is a no-op on macOS 14 to 26:
        // DS.Font.galleryScale (set in main.swift) does the work. The body font lets text
        // without a token inherit the scaled body.
        root = AnyView(root.dynamicTypeSize(.xxxLarge).font(DS.Font.body))
    }
    if standIn {
        // The material stand-in is translucent over the canvas; Reduce Transparency swaps
        // it for the opaque window background, as the real panel material does (§3.5).
        root = options.reduceTransparency
            ? AnyView(root.background(DS.Color.panelStandInOpaque))
            : AnyView(root.background(DS.Color.panelStandIn).background(DS.Color.canvas))
    }
    return root
}

/// Draws `view` into a bitmap at exactly 2× its point size.
@MainActor func capture(_ view: NSView) -> NSBitmapImageRep {
    let size = view.bounds.size
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
        fatalError("RelayGallery: can't allocate a \(size) bitmap")
    }
    rep.size = size
    view.cacheDisplay(in: view.bounds, to: rep)
    return rep
}

func write(_ rep: NSBitmapImageRep, to path: String) {
    guard let data = rep.representation(using: .png, properties: [:]) else {
        FileHandle.standardError.write(Data("RelayGallery: couldn't encode \(path)\n".utf8))
        exit(1)
    }
    do {
        try data.write(to: URL(fileURLWithPath: path))
    } catch {
        FileHandle.standardError.write(Data("RelayGallery: couldn't write \(path): \(error.localizedDescription)\n".utf8))
        exit(1)
    }
    print("wrote \(path) \(rep.pixelsWide)×\(rep.pixelsHigh)")
}

/// A SwiftUI scene hosted in an offscreen borderless window. A nil `height`
/// sizes the scene to its content, with no cap.
@MainActor func hostedCapture(_ scene: GalleryScene, width: CGFloat, height: CGFloat?,
                              options: GalleryOptions, appearance: NSAppearance?) -> NSBitmapImageRep {
    let root = decorated(scene.view(), options: options, standIn: scene.standIn)
    let h: CGFloat
    if let height {
        h = height
    } else {
        let measure = NSHostingController(rootView: AnyView(root.frame(width: width)))
        h = ceil(measure.sizeThatFits(in: CGSize(width: width, height: 100_000)).height)
    }
    let host = NSHostingView(rootView: AnyView(root.frame(width: width, height: h)))
    host.sizingOptions = []
    host.frame = NSRect(x: 0, y: 0, width: width, height: h)
    let win = KeyWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    win.appearance = appearance
    win.contentView = host
    win.setFrameOrigin(NSPoint(x: -20000, y: -20000))
    host.layoutSubtreeIfNeeded()
    RunLoop.current.run(until: Date().addingTimeInterval(0.3))
    if let table = tables(host).first(where: { $0.selectedRow >= 0 }) { win.makeFirstResponder(table) }
    RunLoop.current.run(until: Date().addingTimeInterval(0.6))
    host.layoutSubtreeIfNeeded()
    host.displayIfNeeded()
    let rep = capture(host)
    win.contentView = nil
    return rep
}

/// The Settings toolbar's tab labels.
func tabTitle(_ id: SettingsTabID) -> String {
    switch id {
    case .general: "General"
    case .panel: "Panel"
    case .queue: "Queue"
    case .notifications: "Notifications"
    case .connect: "Connect"
    }
}

func tabSymbol(_ id: SettingsTabID) -> String {
    switch id {
    case .general: DS.Symbol.tabGeneral
    case .panel: DS.Symbol.tabPanel
    case .queue: DS.Symbol.tabQueue
    case .notifications: DS.Symbol.tabNotifications
    case .connect: DS.Symbol.tabConnect
    }
}

/// One Settings tab inside a real `.toolbar` tab window, captured with its title bar.
@MainActor func settingsCapture(_ scene: GalleryScene, tab: String, options: GalleryOptions,
                                appearance: NSAppearance?) -> NSBitmapImageRep {
    let width = DS.Metric.settingsWidth
    let tabs = NSTabViewController()
    tabs.tabStyle = .toolbar
    tabs.canPropagateSelectedChildViewControllerTitle = false
    let specs = SettingsTabID.allCases.map { id in (id: id, title: tabTitle(id), symbol: tabSymbol(id)) }
    guard let selected = specs.firstIndex(where: { $0.id.rawValue == tab }) else {
        fatalError("RelayGallery: scene \(scene.name) names unknown Settings tab \(tab)")
    }
    var contentHeight: CGFloat = 0
    for (index, spec) in specs.enumerated() {
        let rooted: AnyView = index == selected
            ? AnyView(decorated(scene.view(), options: options, standIn: false).frame(width: width))
            : AnyView(EmptyView())
        if index == selected {
            contentHeight = NSHostingView(rootView: rooted).fittingSize.height
        }
        let item = NSTabViewItem(viewController: NSHostingController(rootView: rooted))
        item.label = spec.title
        item.image = NSImage(systemSymbolName: spec.symbol, accessibilityDescription: spec.title)
        item.identifier = spec.id.rawValue
        tabs.addTabViewItem(item)
    }
    tabs.selectedTabViewItemIndex = selected
    let win = KeyWindow(contentViewController: tabs)
    win.title = specs[selected].title
    win.styleMask = [.titled, .closable]
    win.toolbarStyle = .preference
    win.appearance = appearance
    win.setContentSize(NSSize(width: width, height: contentHeight))
    win.setFrameOrigin(NSPoint(x: -20000, y: -20000))
    guard let frameView = win.contentView?.superview else {
        fatalError("RelayGallery: Settings window has no frame view")
    }
    frameView.layoutSubtreeIfNeeded()
    RunLoop.current.run(until: Date().addingTimeInterval(0.8))
    frameView.displayIfNeeded()
    return capture(frameView)
}

@MainActor func appKitCapture(_ scene: GalleryScene, size: NSSize, appearance: NSAppearance?) -> NSBitmapImageRep {
    guard let make = scene.appKit else { fatalError("RelayGallery: scene \(scene.name) has no AppKit view") }
    let view = make()
    view.frame = NSRect(origin: .zero, size: size)
    let window = KeyWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.appearance = appearance
    window.contentView = view
    window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
    view.layoutSubtreeIfNeeded()
    RunLoop.current.run(until: Date().addingTimeInterval(0.3))
    view.displayIfNeeded()
    let rep = capture(view)
    window.contentView = nil
    return rep
}

/// Renders `scene` in light and dark: `<scene>-<theme><suffix>.png`, 2×, into options.outDir.
@MainActor func render(_ scene: GalleryScene, options: GalleryOptions) -> RenderResult {
    var files: [String] = []
    for theme in themes {
        let appearance = NSAppearance(named: theme.appearance)
        let rep: NSBitmapImageRep
        switch scene.size {
        case .panel(let height):
            rep = hostedCapture(scene, width: DS.Metric.panelWidth, height: height, options: options, appearance: appearance)
        case .wide(let width, let height):
            rep = hostedCapture(scene, width: width, height: height, options: options, appearance: appearance)
        case .settings(let tab):
            rep = settingsCapture(scene, tab: tab, options: options, appearance: appearance)
        case .appKit(let size):
            rep = appKitCapture(scene, size: size, appearance: appearance)
        }
        let file = "\(scene.name)-\(theme.name)\(options.fileSuffix).png"
        write(rep, to: (options.outDir as NSString).appendingPathComponent(file))
        files.append(file)
    }
    return RenderResult(files: files)
}
