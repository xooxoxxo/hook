import AppKit
import RelayCore
import SwiftUI

/// Design/ExpectLine (design §3.2): what a step's command should print, "Expect: <expect>".
public struct ExpectLine: View {
    let expect: String

    public init(_ expect: String) {
        self.expect = expect
    }

    public var body: some View {
        Label {
            Text(verbatim: Self.text(expect)).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: DS.Symbol.expect)
        }
        .font(DS.Font.prose)
        .foregroundStyle(DS.Color.secondary)
    }

    public static func text(_ expect: String) -> String { "Expect: " + prose(expect) }
}
