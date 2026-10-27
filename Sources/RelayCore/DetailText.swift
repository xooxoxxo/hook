import Foundation

/// A step's `detail` as inline Markdown: **bold**, *italic*, `code` and [links](https://…),
/// with its line breaks kept. Block syntax (headings, lists) stays as typed text, so a
/// numbered line reads as written.
///
/// The text is untrusted: hidden characters are revealed first (as `prose()` does), and a
/// link survives only when it is a web address `LinkDisplay.isWeb` accepts. Any other link
/// (file:, relay:, javascript:, a relative one) becomes plain text. Images are never loaded.
public enum DetailText {
    public static func attributed(_ raw: String) -> AttributedString {
        let revealed = Sanitize.reveal(raw, as: .prose).text
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false,
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible)
        guard var text = try? AttributedString(markdown: revealed, options: options) else {
            return AttributedString(revealed)
        }
        for run in text.runs {
            if let link = run.link, !LinkDisplay.isWeb(link.absoluteString) {
                text[run.range].link = nil
            }
            if run.imageURL != nil {
                text[run.range].imageURL = nil
            }
        }
        return text
    }

    /// The full address of every link left in `text`, one per line, for the text's
    /// tooltip: a label never hides where its link goes. "" when there is none.
    public static func linkHelp(_ text: AttributedString) -> String {
        var seen = Set<String>()
        return text.runs.compactMap(\.link).map(\.absoluteString)
            .filter { seen.insert($0).inserted }
            .map { Sanitize.revealLine($0) }
            .joined(separator: "\n")
    }
}
