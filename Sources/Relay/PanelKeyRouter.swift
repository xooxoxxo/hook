import AppKit
import RelayCore
import RelayUI

/// The panel-wide keys. SidePanel hands every key equivalent, and every Esc
/// nothing else took, here first. KeyMap decides; this finds the context and carries the
/// command out. Commands on the window itself are done here, the rest by the model.
@MainActor final class PanelKeyRouter {
    /// Keys text editing also uses; inside a field they keep their text meaning.
    static let textEditingKeys: Set<PanelKey> = [.cmdZ, .shiftCmdZ, .cmdDelete, .cmdUp, .cmdDown]

    private let model: any PanelViewModel

    init(model: any PanelViewModel) {
        self.model = model
    }

    static func textFieldFocused(_ window: NSWindow) -> Bool {
        KeyResponder.textFieldFocused(window)
    }

    /// True when the key was the panel's (performed, or handed to text editing). Only ⌘
    /// combinations are taken here (routing rule 1): a plain key AppKit offers as a key
    /// equivalent stays with PanelKeys, which knows the focused closed-today header. Esc comes
    /// through SidePanel.cancelOperation, which calls route directly.
    func handle(_ event: NSEvent, in window: NSWindow) -> Bool {
        guard event.type == .keyDown,
              KeyResponder.isCommandCombination(event.modifierFlags),
              let key = PanelKey(keyCode: event.keyCode, modifiers: KeyResponder.modifiers(event.modifierFlags),
                                 characters: event.charactersIgnoringModifiers)
        else { return false }
        return route(key, event: event, in: window)
    }

    func route(_ key: PanelKey, event: NSEvent?, in window: NSWindow) -> Bool {
        let typing = Self.textFieldFocused(window)
        let context = model.keyContext(textFieldFocused: typing, popoverOpen: false, closedHeaderFocused: false)
        if let command = KeyMap.command(for: key, in: context) {
            perform(command, in: window)
            return true
        }
        // In a field, a text-editing key goes to text editing before any button's shortcut.
        guard typing, let event, Self.textEditingKeys.contains(key) else { return false }
        if key == .cmdZ || key == .shiftCmdZ {
            return NSApp.mainMenu?.performKeyEquivalent(with: event) ?? false
        }
        window.firstResponder?.keyDown(with: event)
        return true
    }

    private func perform(_ command: PanelCommand, in window: NSWindow) {
        switch command {
        case .endEditing:
            window.makeFirstResponder(nil)
        case .focusReply:
            NotificationCenter.default.post(name: .relayFocusReply, object: nil)
        default:
            model.perform(command)
        }
    }
}
