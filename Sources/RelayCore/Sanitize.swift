import Foundation

/// How strictly a field is checked for hidden characters. The mailbox service
/// applies the same policy.
public enum FieldClass: Sendable {
    /// Step.code and verify.code: every hidden character, including variation
    /// selectors and the zero-width joiner.
    case code
    /// Every other string. ZWJ (U+200D), U+FE0E and U+FE0F stay, because emoji need them.
    case prose
}

/// Makes characters that render invisibly, or reorder text, visible as "⟨U+XXXX⟩".
///
/// Where ask-derived text is shown, and the helper it goes through (design §4.15;
/// the 0.5 places in map-panel §5 stay as they were). `line()` is `revealLine`,
/// `prose()` is `reveal(_:as: .prose).text`, both in RelayUI's Sanitized.swift.
///
/// | Text | Helper |
/// |---|---|
/// | AskRow and closed-row VoiceOver labels (title, project) | `line()` |
/// | Detail header meta (project, unknown urgency) | `line()` |
/// | Undo bar title, Notice "<title>", "New Now ask" announcement | `line()` |
/// | Every error reason (Notice, status popover, Settings status, ReplyBox, Welcome) | `UserFacingError.text` → `revealLine` |
/// | "You chose: X" | `revealLine(X)` (ReplyText.display) |
/// | Choice radio labels | `line()` |
/// | From Folder / Host / Session | `line()` each, wrapped |
/// | Non-web URL and link shown as text | `line()` |
/// | Menu-bar tooltip reason | `revealLine` (MenuBarState.tooltip) |
/// | Project section header, QueueMenu items, FilterToken, "Show Only <project>", "Nothing waiting in <project>", "New Now ask in <project>", "Showing only <project>" | `line()`; the filter stores and compares the raw string |
/// | ReplyBox and ChoiceGroup prompt | `prose()`; its VoiceOver label and the picker label use `line()` |
/// | RepliesList reply text | `prose()` |
/// | FromDisclosure title | `line()` |
/// | Sub-step place, action, detail, URL, code, expect | as a step's: `line()`, `prose()`, `CodeBlock` |
/// | Telegram sub-step lines (mailbox) | `html.escape`, as the step lines |
/// | The owner's own draft | not sanitized |
public enum Sanitize {
    public static func reveal(_ s: String, as cls: FieldClass) -> (text: String, hidden: Bool) {
        var text = ""
        var hidden = false
        for scalar in s.unicodeScalars {
            if isHidden(scalar, as: cls) {
                text += marker(scalar)
                hidden = true
            } else {
                text.unicodeScalars.append(scalar)
            }
        }
        return (text, hidden)
    }

    /// What a Copy button puts on the pasteboard: exactly the displayed code,
    /// minus trailing whitespace, so a paste never ends in a newline that runs it.
    /// Trailing whitespace is trimmed before revealing, so a trailing CR (as in
    /// CRLF) is dropped rather than turned into a marker; a CR elsewhere is revealed.
    public static func copyText(_ code: String) -> String {
        var raw = code
        while let last = raw.unicodeScalars.last, last.properties.isWhitespace {
            raw.unicodeScalars.removeLast()
        }
        return reveal(raw, as: .code).text
    }

    /// Prose for a single-line field (title, step.do, link label, …): LF and TAB
    /// are revealed too, so a value cannot pose as more than one line.
    public static func revealLine(_ s: String) -> String {
        var text = ""
        for scalar in reveal(s, as: .prose).text.unicodeScalars {
            if scalar == "\n" || scalar == "\t" {
                text += marker(scalar)
            } else {
                text.unicodeScalars.append(scalar)
            }
        }
        return text
    }

    /// THE RULE, shared with the mailbox service: a scalar is hidden when its general
    /// category is Cc, Cf, Cs, Co, Cn, Zl or Zp, or it is a
    /// Default_Ignorable_Code_Point. TAB and LF are always allowed; prose also
    /// keeps ZWJ (U+200D) and the presentation selectors U+FE0E / U+FE0F.
    static func isHidden(_ scalar: Unicode.Scalar, as cls: FieldClass) -> Bool {
        let v = scalar.value
        if v == 0x09 || v == 0x0A { return false }
        if cls == .prose, v == 0x200D || v == 0xFE0E || v == 0xFE0F { return false }
        let props = scalar.properties
        switch props.generalCategory {
        case .control, .format, .surrogate, .privateUse, .unassigned,
             .lineSeparator, .paragraphSeparator:
            return true
        default:
            return props.isDefaultIgnorableCodePoint
        }
    }

    private static func marker(_ scalar: Unicode.Scalar) -> String {
        "⟨U+" + String(format: "%04X", scalar.value) + "⟩"
    }
}
