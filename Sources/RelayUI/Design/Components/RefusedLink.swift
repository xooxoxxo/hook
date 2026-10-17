import AppKit
import RelayCore
import SwiftUI

/// Design/RefusedLink (design §3.2): a link that won't open (not http or https), shown grey
/// with its raw address under it so the owner can still read it.
///
/// `text` is already sanitized (`LinkDisplay.refusedText`); `raw` goes through `line()`.
public struct RefusedLink: View {
    let text: String
    let raw: String

    public init(text: String, raw: String) {
        self.text = text
        self.raw = raw
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.rowLine) {
            Label(text, systemImage: DS.Symbol.link)
                .foregroundStyle(DS.Color.secondary)
            Text(verbatim: line(raw)).textSelection(.enabled).foregroundStyle(DS.Color.secondary)
        }
        .font(DS.Font.prose)
    }
}
