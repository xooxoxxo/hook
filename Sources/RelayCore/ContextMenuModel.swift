import Foundation

/// What a row's context menu item does (design §4.3 "Context menu").
public enum ContextCommand: Equatable, Sendable {
    case open, done, skip, reopen, showOnly(String), showAll, copyLink, copyResume
}

public enum ContextMenuEntry: Equatable, Sendable {
    /// `shortcut` is the key as the menu shows it; the view attaches the real key equivalent.
    case item(title: String, command: ContextCommand, shortcut: String?)
    case separator
}

/// A queue row's context menu as data. Every item also has a panel key (§4.12).
public enum QueueContextMenu {
    public static let projectTitleMax = 40

    public static func entries(for row: AskRowModel, filter: String?) -> [ContextMenuEntry] {
        var entries: [ContextMenuEntry] = [.item(title: "Open", command: .open, shortcut: "↩")]
        if row.isOpen {
            entries.append(.item(title: "Done", command: .done, shortcut: "⌘↩"))
            entries.append(.item(title: "Skip", command: .skip, shortcut: "⌘⌫"))
        } else {
            entries.append(.item(title: "Reopen", command: .reopen, shortcut: "⇧⌘R"))
        }
        if let project = projectEntry(row.project, filter: filter) {
            entries += [.separator, project]
        }
        entries += [.separator, .item(title: "Copy Link", command: .copyLink, shortcut: "⇧⌘L")]
        if row.isOpen, row.resumeCommand != nil {
            entries.append(.item(title: "Copy Resume Command", command: .copyResume, shortcut: nil))
        }
        return entries
    }

    /// "Show Only <project>", or "Show All Projects" while the filter is already that
    /// project; nothing for an ask without a project. The title is sanitized (§4.15);
    /// the command carries the raw project, which is what the filter stores.
    static func projectEntry(_ project: String, filter: String?) -> ContextMenuEntry? {
        guard !project.isEmpty else { return nil }
        if filter == project {
            return .item(title: "Show All Projects", command: .showAll, shortcut: "⌃⌘A")
        }
        let name = middleTruncated(Sanitize.revealLine(project), max: projectTitleMax)
        return .item(title: "Show Only " + name, command: .showOnly(project), shortcut: "⌃⌘P")
    }

    /// At most `max` characters, the middle replaced by "…".
    public static func middleTruncated(_ text: String, max: Int) -> String {
        guard text.count > max, max > 1 else { return text }
        let keep = max - 1
        let head = keep / 2
        return String(text.prefix(head)) + "…" + String(text.suffix(keep - head))
    }

    public static func link(for id: String) -> String {
        "relay://i/" + id
    }
}
