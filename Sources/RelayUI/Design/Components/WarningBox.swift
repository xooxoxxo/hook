import RelayCore
import SwiftUI

/// Design/WarningBox: the tinted box on a blocking step, with its `warning` (or
/// `Flow.blockingWarning`). It shows on the row whether the row is open or not.
public struct WarningBox: View {
    let text: String

    public init(_ text: String) {
        self.text = text
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: DS.Metric.codeRadius, style: .continuous)
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.inline) {
            Image(systemName: DS.Symbol.warning)
                .foregroundStyle(DS.Color.warn)
                .accessibilityHidden(true)
            Text(verbatim: prose(text))
                .font(DS.Font.prose)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, DS.Space.codeH)
        .padding(.vertical, DS.Space.codeV)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(shape.fill(DS.Color.warnFill))
        .overlay(shape.strokeBorder(DS.Color.warnStroke, lineWidth: DS.Metric.cardBorder))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Self.accessibilityText(text))
    }

    /// "Warning: <text>".
    public static func accessibilityText(_ text: String) -> String { "Warning: " + line(text) }
}
