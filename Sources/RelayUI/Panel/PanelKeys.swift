import AppKit
import RelayCore
import SwiftUI

/// Facts about the key window that both key paths need.
public enum KeyResponder {
    /// True while a text field is being edited: the first responder is an editable text view
    /// (a field editor or a multi-line field) or a text field. A selectable, read-only text
    /// view (step text with selection on) does not count.
    @MainActor public static func textFieldFocused(_ window: NSWindow?) -> Bool {
        guard let responder = window?.firstResponder else { return false }
        if let text = responder as? NSTextView { return text.isEditable }
        return responder is NSTextField
    }

    /// The four modifiers KeyMap reads; caps lock, function and keypad flags are dropped.
    public static func modifiers(_ flags: NSEvent.ModifierFlags) -> KeyModifiers {
        var modifiers: KeyModifiers = []
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.control) { modifiers.insert(.control) }
        return modifiers
    }
}

/// The plain panel keys (design §4.12): Esc, Return, ⌥Return, ← / →, 1–6, when the focused
/// view didn't take them. ⌘ combinations arrive through SidePanel.performKeyEquivalent.
public struct PanelKeys: ViewModifier {
    private let model: any PanelViewModel
    @FocusedValue(\.relayClosedHeaderFocused) private var closedHeaderFocused

    public init(model: some PanelViewModel) {
        self.model = model
    }

    /// A key press as a panel key; nil for anything with ⌘, ⌃ or ⇧.
    static func key(_ key: KeyEquivalent, modifiers: EventModifiers, characters: String) -> PanelKey? {
        // Caps lock, keypad and function flags (arrows carry the last two) don't count.
        let modifiers = modifiers.intersection([.command, .shift, .option, .control])
        switch (key, modifiers) {
        case (.escape, []): return .escape
        case (.return, []): return .returnKey
        case (.return, .option): return .optionReturn
        case (.leftArrow, []): return .left
        case (.rightArrow, []): return .right
        default:
            guard modifiers.isEmpty, let digit = Int(characters), (1...6).contains(digit) else { return nil }
            return .digit(digit)
        }
    }

    public func body(content: Content) -> some View {
        content.onKeyPress(phases: .down) { press in
            guard let key = Self.key(press.key, modifiers: press.modifiers, characters: press.characters) else {
                return .ignored
            }
            let window = NSApp.keyWindow
            let context = model.keyContext(textFieldFocused: KeyResponder.textFieldFocused(window), popoverOpen: false,
                                           closedHeaderFocused: closedHeaderFocused ?? false)
            guard let command = KeyMap.command(for: key, in: context) else { return .ignored }
            switch command {
            case .endEditing:
                window?.makeFirstResponder(nil)
            case .focusReply:
                NotificationCenter.default.post(name: .relayFocusReply, object: nil)
            case .setClosedExpanded(let expanded):
                UserDefaults.standard.set(expanded, forKey: "relay.closedToday.expanded")
            default:
                model.perform(command)
            }
            return .handled
        }
    }
}
