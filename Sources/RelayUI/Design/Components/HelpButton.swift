import SwiftUI

/// The text style of the label a "?" sits beside, so the glyph can centre on its capitals.
/// A plain enum: safe as a default value anywhere.
public enum HelpLabelStyle: Sendable, Equatable, CaseIterable {
    case body, heading, prose, caption, subheadline
}

private struct HelpLabelStyleKey: EnvironmentKey { static let defaultValue = HelpLabelStyle.body }

extension EnvironmentValues {
    /// The label style of the row a `HelpButton` sits in; `.body` unless the row says otherwise.
    public var helpLabelStyle: HelpLabelStyle {
        get { self[HelpLabelStyleKey.self] }
        set { self[HelpLabelStyleKey.self] = newValue }
    }
}

extension View {
    /// Tells every `HelpButton` inside which text style its label uses.
    public func helpLabelStyle(_ style: HelpLabelStyle) -> some View {
        environment(\.helpLabelStyle, style)
    }
}

/// The "?" that opens a 300 pt selectable popover: a small outlined glyph in tertiary,
/// always shown (owner pick 2). In a `.firstTextBaseline` row it centres on its label's
/// capitals; in a centre-aligned row (Settings) it keeps the row's centre.
/// Explanations live here, never inline. `text` is Hook's own copy, not ask text.
public struct HelpButton: View {
    let rowLabel: String
    let text: String
    @State private var open = false
    @Environment(\.helpLabelStyle) private var style

    static let symbol = DS.Symbol.helpOutline
    static var font: Font { DS.Font.caption }
    static let foreground = DS.Color.tertiary

    public init(rowLabel: String, text: String) {
        self.rowLabel = rowLabel
        self.text = text
    }

    public var body: some View {
        Button { open = true } label: {
            Image(systemName: Self.symbol)
                .font(Self.font)
                .foregroundStyle(Self.foreground)
                .contentShape(.rect)
        }
        .buttonStyle(.borderless)
        .help("Help")
        .accessibilityLabel(Self.accessibilityLabel(rowLabel: rowLabel))
        .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + DS.Font.capHeight(style) / 2 }
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
