import AppKit
import SwiftUI

enum SettingsTab: String, CaseIterable {
    case general, queue, notifications, connect

    var title: String {
        switch self {
        case .general: "General"
        case .queue: "Queue"
        case .notifications: "Notifications"
        case .connect: "Connect"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .queue: "tray"
        case .notifications: "bell"
        case .connect: "link"
        }
    }
}

/// "Relay Settings": a fixed-size window with native toolbar tabs. The
/// last tab used is remembered. AppDelegate fills Queue, Notifications and Connect
/// with `setContent` at launch.
@MainActor final class SettingsWindowController {
    static let tabDefaultsKey = "relay.settings.tab"
    /// Lets tabs pick this window's `willCloseNotification` out of every window's.
    static let windowID = NSUserInterfaceItemIdentifier("relay.settings")

    private let tabs = SettingsTabViewController()
    private let window: NSWindow

    init(model: AppModel, hotKeys: HotKeyManager) {
        tabs.tabStyle = .toolbar
        tabs.canPropagateSelectedChildViewControllerTitle = false
        tabs.title = "Relay Settings"
        for tab in SettingsTab.allCases {
            let content: NSViewController = tab == .general
                ? Self.hosting(GeneralTab(model: model, hotKeys: hotKeys))
                : NSHostingController(rootView: EmptyView())
            tabs.addTabViewItem(Self.item(tab, content))
        }
        window = NSWindow(contentViewController: tabs)
        window.title = "Relay Settings"
        window.identifier = Self.windowID
        window.styleMask = [.titled, .closable]
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        // Set after the items exist, so building the tabs doesn't overwrite the saved one.
        tabs.onSelect = { tab in
            UserDefaults.standard.set(tab.rawValue, forKey: Self.tabDefaultsKey)
        }
    }

    /// Opens on `tab`, or on the last tab used.
    func show(tab: SettingsTab? = nil) {
        let saved = UserDefaults.standard.string(forKey: Self.tabDefaultsKey).flatMap(SettingsTab.init(rawValue:))
        if let index = SettingsTab.allCases.firstIndex(of: tab ?? saved ?? .general) {
            tabs.selectedTabViewItemIndex = index
        }
        if !window.isVisible { window.center() }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    /// Replaces one tab's content, keeping the selected tab.
    func setContent(_ tab: SettingsTab, _ controller: NSViewController) {
        guard let index = SettingsTab.allCases.firstIndex(of: tab) else { return }
        let selected = tabs.selectedTabViewItemIndex
        tabs.isRebuilding = true
        tabs.removeTabViewItem(tabs.tabViewItems[index])
        tabs.insertTabViewItem(Self.item(tab, controller), at: index)
        tabs.selectedTabViewItemIndex = selected
        tabs.isRebuilding = false
    }

    /// SwiftUI content whose fitting size drives the window size.
    static func hosting<Content: View>(_ view: Content) -> NSViewController {
        let controller = NSHostingController(rootView: view)
        controller.sizingOptions = [.preferredContentSize]
        return controller
    }

    private static func item(_ tab: SettingsTab, _ controller: NSViewController) -> NSTabViewItem {
        let item = NSTabViewItem(viewController: controller)
        item.identifier = tab.rawValue
        item.label = tab.title
        item.image = NSImage(systemSymbolName: tab.symbol, accessibilityDescription: tab.title)
        return item
    }
}

/// Reports tab changes the owner makes, for the remembered tab.
private final class SettingsTabViewController: NSTabViewController {
    var onSelect: (@MainActor (SettingsTab) -> Void)?
    var isRebuilding = false

    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        guard !isRebuilding, let id = tabViewItem?.identifier as? String, let tab = SettingsTab(rawValue: id) else { return }
        onSelect?(tab)
    }
}
