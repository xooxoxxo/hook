import AppKit

/// The main menu. Relay has no Dock icon, so the menu is never seen,
/// but its key equivalents reach Relay's windows: ⌘C/⌘V in text fields,
/// ⌘, for Settings, ⌘R to refresh, ⌘Q to quit.
enum MainMenu {
    @MainActor static func install(settings: Selector, refresh: Selector, target: AnyObject) {
        let main = NSMenu()

        let app = NSMenu(title: "Relay")
        app.addItem(entry("Settings…", settings, ",", target: target))
        app.addItem(.separator())
        app.addItem(entry("Quit Relay", #selector(NSApplication.terminate(_:)), "q"))
        main.addItem(holder(app))

        let edit = NSMenu(title: "Edit")
        edit.addItem(entry("Undo", Selector(("undo:")), "z"))
        let redo = entry("Redo", Selector(("redo:")), "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(redo)
        edit.addItem(.separator())
        edit.addItem(entry("Cut", #selector(NSText.cut(_:)), "x"))
        edit.addItem(entry("Copy", #selector(NSText.copy(_:)), "c"))
        edit.addItem(entry("Paste", #selector(NSText.paste(_:)), "v"))
        edit.addItem(entry("Select All", #selector(NSText.selectAll(_:)), "a"))
        main.addItem(holder(edit))

        let queue = NSMenu(title: "Queue")
        queue.addItem(entry("Refresh", refresh, "r", target: target))
        main.addItem(holder(queue))

        NSApp.mainMenu = main
    }

    /// `target` nil sends the action down the responder chain (Edit items, Quit).
    @MainActor private static func entry(_ title: String, _ action: Selector, _ key: String,
                                         target: AnyObject? = nil) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: key)
        entry.target = target
        return entry
    }

    @MainActor private static func holder(_ menu: NSMenu) -> NSMenuItem {
        let holder = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        holder.submenu = menu
        return holder
    }
}
