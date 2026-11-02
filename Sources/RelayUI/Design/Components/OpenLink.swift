import AppKit
import RelayCore
import SwiftUI

/// Design/OpenLink: a web link that opens in the browser. Only build one for a
/// URL `LinkDisplay.isWeb` accepts; anything else is a `RefusedLink`. `title` is already
/// sanitized (`LinkDisplay.stepTitle` or `LinkDisplay.linkTitle`).
public struct OpenLink: View {
    let title: String
    let url: URL
    @Environment(\.askContentLocked) private var contentLocked

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
            ForEach(Self.menuItems(locked: contentLocked), id: \.self) { item in
                Button(item) { copyAddress() }
            }
        }
        .disabled(!AskContentLock.allowsActions(locked: contentLocked))
    }

    public static let copyAddressItem = "Copy Link Address"

    /// The context menu: none while the ask's content is locked for review.
    public static func menuItems(locked: Bool) -> [String] {
        AskContentLock.allowsCopy(locked: locked) ? [copyAddressItem] : []
    }

    private func copyAddress() {
        guard AskContentLock.allowsCopy(locked: contentLocked) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }

    public static func accessibilityText(_ title: String) -> String { title + ", link" }
}
