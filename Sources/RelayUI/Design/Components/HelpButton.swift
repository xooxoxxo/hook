import SwiftUI

/// The "?" (stock HelpLink) that opens a 300 pt selectable popover.
/// Explanations live here, never inline. `text` is Relay's own copy, not ask text.
public struct HelpButton: View {
    let rowLabel: String
    let text: String
    @State private var open = false

    public init(rowLabel: String, text: String) {
        self.rowLabel = rowLabel
        self.text = text
    }

    public var body: some View {
        HelpLink { open = true }
            .accessibilityLabel(Self.accessibilityLabel(rowLabel: rowLabel))
            .popover(isPresented: $open, arrowEdge: .bottom) {
                Text(text)
                    .font(DS.Font.prose)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .padding(DS.Space.popover)
                    .frame(width: DS.Metric.helpWidth)
            }
    }

    public static func accessibilityLabel(rowLabel: String) -> String { "Help: " + rowLabel }
}
