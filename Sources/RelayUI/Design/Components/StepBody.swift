import RelayCore
import SwiftUI

/// Design/StepBody (design §3.2): a step's detail, link, command and expected output, in that
/// order. It is a `Group`, so its parts sit in the caller's `VStack(spacing: stepPart)`.
public struct StepBody: View {
    let content: StepContent
    let level: StepLevel
    let onCopy: (String) -> Void

    public init(content: StepContent, level: StepLevel, onCopy: @escaping (String) -> Void) {
        self.content = content
        self.level = level
        self.onCopy = onCopy
    }

    public var body: some View {
        Group {
            if let detail = content.detail {
                Text(verbatim: prose(detail))
                    .font(DS.Font.prose)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
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
