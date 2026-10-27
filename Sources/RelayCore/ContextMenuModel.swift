import Foundation

/// What a row's context menu item does.
public enum ContextCommand: Equatable, Sendable {
    case open, done, skip, reopen, showOnly(String), showAll, copyLink, copyResume, resume
}

public enum ContextMenuEntry: Equatable, Sendable {
    /// `shortcut` is the key as the menu shows it; the view attaches the real key equivalent.
    case item(title: String, command: ContextCommand, shortcut: String?)
    /// Shown dimmed, with `reason` on a dimmed line under it.
    case disabled(title: String, reason: String)
    case separator
}

/// A queue row's context menu as data. Every item also has a panel key.
public enum QueueContextMenu {
    public static let projectTitleMax = 40

    public static let resumeTitle = "Resume Session"
    public static let copyResumeTitle = "Copy Resume Command"

    /// `localHost` is this Mac's host name, read once by the app (`HostName.current`) and
    /// passed in, never looked up per row; Resume Session is enabled only for a session on it.
    public static func entries(for row: AskRowModel, filter: String?, localHost: String?) -> [ContextMenuEntry] {
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
        entries += resumeEntries(for: row, localHost: localHost)
        return entries
    }

    /// Resume Session (enabled, or dimmed with why) and Copy Resume Command, for an
    /// open or closed ask with a resume command. The queue menu and the detail's
    /// header menu both use these.
    public static func resumeEntries(for row: AskRowModel, localHost: String?) -> [ContextMenuEntry] {
        var entries: [ContextMenuEntry] = []
        switch ResumeAvailability.of(row.origin, localHost: localHost) {
        case .none: break
        case .available: entries.append(.item(title: resumeTitle, command: .resume, shortcut: nil))
        case .unavailable(let reason): entries.append(.disabled(title: resumeTitle, reason: reason))
        }
        if row.resumeCommand != nil {
            entries.append(.item(title: copyResumeTitle, command: .copyResume, shortcut: nil))
        }
        return entries
    }

    /// "Show Only <project>", or "Show All Projects" while the filter is already that
    /// project; nothing for an ask without a project. The title is sanitized;
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
