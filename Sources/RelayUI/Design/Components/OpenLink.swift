import AppKit
import RelayCore
import SwiftUI

/// Design/OpenLink (design §3.2): a web link that opens in the browser. Only build one for a
/// URL `LinkDisplay.isWeb` accepts; anything else is a `RefusedLink`. `title` is already
/// sanitized (`LinkDisplay.stepTitle` or `LinkDisplay.linkTitle`).
public struct OpenLink: View {
    let title: String
    let url: URL

    public init(title: String, url: URL) {
        self.title = title
        self.url = url
    }

    public var body: some View {
        Link(destination: url) {
            Label(title, systemImage: DS.Symbol.openLink)
        }
        .font(DS.Font.prose)
        .lineLimit(1)
        .truncationMode(.middle)
        .help(line(url.absoluteString))
        .accessibilityLabel(Self.accessibilityText(title))
        .contextMenu {
            Button("Copy Link Address") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url.absoluteString, forType: .string)
            }
        }
    }

    public static func accessibilityText(_ title: String) -> String { title + ", link" }
}
