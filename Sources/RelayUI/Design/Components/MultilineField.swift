#if os(macOS)
import AppKit
#endif
import RelayCore
import SwiftUI

/// Design/MultilineField: the stock rounded field for a long text (a message, a problem report,
/// a choice's words). It grows with the text up to the top of `lines`, then scrolls. Return adds
/// a line break where the caret is, as ⌥Return does; ⌘Return is left to the panel's key router,
/// which sends. The owner's text is not sanitized: it goes as typed.
public struct MultilineField: View {
    let placeholder: String
    let text: Binding<String>
    let lines: ClosedRange<Int>
    let isFocused: FocusState<Bool>.Binding

    public init(_ placeholder: String, text: Binding<String>, lines: ClosedRange<Int>,
                isFocused: FocusState<Bool>.Binding) {
        self.placeholder = placeholder
        self.text = text
        self.lines = lines
        self.isFocused = isFocused
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: DS.Metric.messageFieldRadius, style: .continuous)
        TextField(placeholder, text: text, axis: .vertical)
            .textFieldStyle(.plain)
            .font(DS.Font.body)
            .lineLimit(lines)
            // Its own height, up to `lines`, whatever the row around it proposes.
            .fixedSize(horizontal: false, vertical: true)
            .focused(isFocused)
            .onKeyPress(.return, phases: [.down, .repeat]) { press in
                Self.addsLineBreak(press.modifiers) && Self.insertLineBreak() ? .handled : .ignored
            }
            .padding(DS.Metric.messageFieldInset * 2)
            .background(DS.Color.fieldFill, in: shape)
            .overlay(shape.strokeBorder(DS.Color.fieldStroke, lineWidth: DS.Metric.messageFieldStroke))
            .accessibilityLabel(placeholder)
    }

    /// Return and ⇧Return add a line; ⌘Return (send) and anything with ⌃ or ⌥ are left alone.
    public static func addsLineBreak(_ modifiers: EventModifiers) -> Bool {
        modifiers.subtracting(.shift).isEmpty
    }

    /// A vertical TextField's field editor ends editing on Return; this asks it for the line
    /// break ⌥Return gives, at the caret. False when no field editor has the keys.
    @MainActor static func insertLineBreak() -> Bool {
#if os(macOS)
        guard let editor = NSApp.keyWindow?.firstResponder as? NSTextView, editor.isFieldEditor else { return false }
        editor.insertNewlineIgnoringFieldEditor(nil)
        return true
#else
        return false
#endif
    }
}
