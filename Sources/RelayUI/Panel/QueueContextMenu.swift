import RelayCore
import SwiftUI

/// A row's context menu from `QueueContextMenu.entries`, also the detail header's menu.
/// Each item shows its panel key.
struct RowContextMenu: View {
    let entries: [ContextMenuEntry]
    let perform: (ContextCommand) -> Void

    init(entries: [ContextMenuEntry], perform: @escaping (ContextCommand) -> Void) {
        self.entries = entries
        self.perform = perform
    }

    static func shortcut(for command: ContextCommand) -> KeyboardShortcut? {
        switch command {
        case .open: KeyboardShortcut(.return, modifiers: [])
        case .done: KeyboardShortcut(.return, modifiers: .command)
        case .skip: KeyboardShortcut(.delete, modifiers: .command)
        case .reopen: KeyboardShortcut("r", modifiers: [.shift, .command])
        case .showOnly: KeyboardShortcut("p", modifiers: [.control, .command])
        case .showAll: KeyboardShortcut("a", modifiers: [.control, .command])
        case .copyLink: KeyboardShortcut("l", modifiers: [.shift, .command])
        case .copyResume, .resume: nil
        }
    }

    var body: some View {
        ForEach(entries.indices, id: \.self) { index in
            switch entries[index] {
            case .separator:
                Divider()
            case let .disabled(title, reason):
                // A dimmed item, then why on its own dimmed line.
                Button(title) {}.disabled(true)
                Text(reason)
            case let .item(title, command, _):
                if let shortcut = Self.shortcut(for: command) {
                    Button(title) { perform(command) }.keyboardShortcut(shortcut)
                } else {
                    Button(title) { perform(command) }
                }
            }
        }
    }
}
