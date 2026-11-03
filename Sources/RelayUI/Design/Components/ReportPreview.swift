import SwiftUI

/// Design/ReportPreview: a crash report exactly as it is sent, monospaced and selectable,
/// with each redaction placeholder tinted so the owner sees what was replaced.
public struct ReportPreview: View {
    let text: String

    public init(text: String) {
        self.text = text
    }

    public var body: some View {
        Text(Self.tinted(text))
            .font(DS.Font.report)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, DS.Space.codeH)
            .padding(.vertical, DS.Space.codeV)
    }

    /// What the redactor puts in place of a value.
    public static let placeholders = ["<redacted>", "<host>", "<user>", "<id>", "~/"]

    /// The text with every placeholder tinted.
    public static func tinted(_ text: String) -> AttributedString {
        var out = AttributedString(text)
        for token in placeholders {
            var search = out.startIndex..<out.endIndex
            while let range = out[search].range(of: token) {
                out[range].foregroundColor = DS.Color.redactedText
                out[range].backgroundColor = DS.Color.redactedFill
                search = range.upperBound..<out.endIndex
            }
        }
        return out
    }

    /// How many placeholders the preview tints, for tests.
    public static func placeholderCount(_ text: String) -> Int {
        placeholders.reduce(0) { $0 + text.components(separatedBy: $1).count - 1 }
    }
}
