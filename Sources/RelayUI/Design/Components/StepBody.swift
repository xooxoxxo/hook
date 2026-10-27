import RelayCore
import SwiftUI

/// Design/StepBody: a step's detail, file, link, command and expected output, in that
/// order. The detail renders inline Markdown (bold, italic, code, web links) with its line
/// breaks kept (`DetailText`). It is a `Group`, so its parts sit in the caller's `VStack(spacing: stepPart)`.
public struct StepBody: View {
    let content: StepContent
    let level: StepLevel
    let onCopy: (String) -> Void

    public init(content: StepContent, level: StepLevel, onCopy: @escaping (String) -> Void) {
        self.content = content
        self.level = level
        self.onCopy = onCopy
    }

    @Environment(\.fileRowContext) private var fileContext
    private var home: String { fileContext.home }

    /// A `file` that isn't an absolute local path (the validator never lets one through).
    public static let refusedFile = "File not shown: not an absolute path"

    public var body: some View {
        Group {
            if let detail = content.detail {
                let text = DetailText.attributed(detail)
                Text(text)
                    .font(DS.Font.prose)
                    .help(DetailText.linkHelp(text))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let raw = content.file {
                if let link = FileLink(raw, home: home) {
                    FileRow(link: link)
                } else {
                    RefusedLink(text: Self.refusedFile, raw: raw)
                }
            }
            if let raw = content.url {
                if let title = LinkDisplay.stepTitle(raw), let url = URL(string: raw) {
                    OpenLink(title: title, url: url)
                } else {
                    RefusedLink(text: LinkDisplay.refusedText(label: nil), raw: raw)
                }
            }
            if let code = content.code {
                // A new command gets a fresh block, so it never inherits a "Copied" state.
                CodeBlock(code: code, copyLabel: StepAccessibility.copyLabel(level: level), lang: content.lang,
                          onCopy: onCopy)
                    .id(code)
            }
            if let expect = content.expect { ExpectLine(expect) }
        }
    }
}
