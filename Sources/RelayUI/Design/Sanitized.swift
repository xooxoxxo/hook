import RelayCore

/// Untrusted single-line text (a title, a project, a step's `do`, a link label, an
/// error reason): hidden characters, LF and TAB are shown as ⟨U+XXXX⟩, so a value
/// can't pose as more than one line or reorder the text around it.
public func line(_ s: String) -> String { Sanitize.revealLine(s) }

/// Untrusted wrapped prose (why, detail, expect, a reply): hidden characters are
/// shown as ⟨U+XXXX⟩; newlines stay.
public func prose(_ s: String) -> String { Sanitize.reveal(s, as: .prose).text }
