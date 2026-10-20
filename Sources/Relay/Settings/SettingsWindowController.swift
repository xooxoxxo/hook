import AppKit
import RelayCore
import RelayUI
import SwiftUI

/// Settings: a stock toolbar-tab window with five tabs, 600 pt content, the window
/// title = the tab name. The tab is remembered by id; ⌘1–⌘5 switch tabs, ⌘W closes.
/// Tabs are built on first show from `AppModel.settingsTab(_:)`.
@MainActor final class SettingsWindowController: NSObject, NSWindowDelegate {
    /// Lets tabs pick this window's `willCloseNotification` out of every window's.
    static let windowID = NSUserInterfaceItemIdentifier("relay.settings")

    private let model: AppModel
    private let tabs = SettingsTabViewController()
    private let window: SettingsWindow
    private var built = false

    init(model: AppModel) {
        self.model = model
        tabs.tabStyle = .toolbar
        tabs.canPropagateSelectedChildViewControllerTitle = true
        window = SettingsWindow(contentViewController: tabs)
        super.init()
        window.styleMask = [.titled, .closable]
        window.toolbarStyle = .preference
        window.identifier = Self.windowID
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.onTab = { [weak self] tab in self?.select(tab) }
    }

    /// Opens on `tab`, or on the remembered one.
    func show(tab: SettingsTabID? = nil) {
        buildIfNeeded()
        let shown = tab ?? SettingsTabID.restore(.standard)
        select(shown)
        // The permission is re-read every time the Notifications tab opens.
        if shown == .notifications { Task { await model.refreshPermission() } }
        // Closing the window stops last-call polling, and re-selecting the already
        // selected tab fires no didSelect, so every show sets it again.
        model.setLastSeenPolling(shown == .connect)
        model.refreshSettings()
        if !window.isVisible { window.center() }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    func select(_ tab: SettingsTabID) {
        guard let index = SettingsTabID.allCases.firstIndex(of: tab) else { return }
        tabs.selectedTabViewItemIndex = index
    }

    /// Replaces one tab's content, keeping the selected tab.
    func setContent(_ tab: SettingsTabID, _ controller: NSViewController) {
        guard built, let index = SettingsTabID.allCases.firstIndex(of: tab) else { return }
        let selected = tabs.selectedTabViewItemIndex
        tabs.isRebuilding = true
        tabs.removeTabViewItem(tabs.tabViewItems[index])
        tabs.insertTabViewItem(Self.item(tab, controller), at: index)
        tabs.selectedTabViewItemIndex = selected
        tabs.isRebuilding = false
    }

    func windowWillClose(_ notification: Notification) {
        model.settingsWindowClosed()
    }

    private func buildIfNeeded() {
        guard !built else { return }
        built = true
        tabs.isRebuilding = true
        for tab in SettingsTabID.allCases {
            tabs.addTabViewItem(Self.item(tab, model.settingsTab(tab)))
        }
        tabs.isRebuilding = false
        tabs.onSelect = { [weak self] tab in
            tab.save(.standard)
            self?.model.setLastSeenPolling(tab == .connect)
            if tab == .notifications, let model = self?.model { Task { await model.refreshPermission() } }
        }
    }

    /// SwiftUI content, 600 pt wide, never taller than the screen allows; past that the Form scrolls.
    static func hosting<Content: View>(_ view: Content) -> NSViewController {
        let controller = NSHostingController(rootView: view
            .frame(width: DS.Metric.settingsWidth)
            .frame(maxHeight: maxContentHeight))
        controller.sizingOptions = [.preferredContentSize]
        return controller
    }

    /// The screen's visible height minus `DS.Metric.settingsInset`.
    static var maxContentHeight: CGFloat {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return .infinity }
        return screen.visibleFrame.height - DS.Metric.settingsInset
    }

    private static func item(_ tab: SettingsTabID, _ controller: NSViewController) -> NSTabViewItem {
        controller.title = tab.title
        let item = NSTabViewItem(viewController: controller)
        item.identifier = tab.rawValue
        item.label = tab.title
        item.image = NSImage(systemSymbolName: tab.symbol, accessibilityDescription: tab.title)
        return item
    }
}

/// ⌘1–⌘5 pick a tab and ⌘W closes, with no menu holding them.
final class SettingsWindow: NSWindow {
    var onTab: (@MainActor (SettingsTabID) -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers == .command, let key = event.charactersIgnoringModifiers {
            if let digit = Int(key), let tab = SettingsTabID(shortcutDigit: digit) {
                onTab?(tab)
                return true
            }
            if key == "w" {
                performClose(nil)
                return true
            }
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// Reports tab changes the owner makes, for the remembered tab.
private final class SettingsTabViewController: NSTabViewController {
    var onSelect: (@MainActor (SettingsTabID) -> Void)?
    var isRebuilding = false

    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        guard !isRebuilding, let id = tabViewItem?.identifier as? String, let tab = SettingsTabID(rawValue: id) else { return }
        onSelect?(tab)
    }
}
