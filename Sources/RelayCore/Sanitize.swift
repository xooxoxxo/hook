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
