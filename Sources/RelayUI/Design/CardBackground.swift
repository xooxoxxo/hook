import SwiftUI

/// Design/CardBackground: a queue card, drawn as the List row's background. It fills the row
/// less half the card gap above and below and `cardEdge` at the sides, so neighbouring cards
/// stand apart. The card draws the selection itself (an accent tint under an accent border),
/// so the List's own highlight is switched off on its table view (`ListHighlightOff`, once
/// per List). A `quiet` card (recently closed) has the fainter fill and its own hairline.
public struct CardBackground: View, Equatable {
    let selected: Bool
    let quiet: Bool
    @Environment(\.colorSchemeContrast) private var contrast

    public init(selected: Bool, quiet: Bool = false) {
        self.selected = selected
        self.quiet = quiet
    }

    nonisolated public static func == (a: CardBackground, b: CardBackground) -> Bool {
        a.selected == b.selected && a.quiet == b.quiet
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: DS.Metric.cardRadius, style: .continuous)
        shape
            .fill(quiet ? DS.Color.cardFillQuiet : DS.Color.cardFill)
            .overlay {
                if selected { shape.fill(DS.Color.cardSelectedFill) }
            }
            .overlay {
                if selected {
                    shape.strokeBorder(DS.Color.cardSelectedStroke, lineWidth: DS.Metric.cardSelectedBorder)
                } else if contrast == .increased {
                    shape.strokeBorder(DS.Color.cardStrokeContrast, lineWidth: DS.Metric.cardBorderContrast)
                } else {
                    shape.strokeBorder(quiet ? DS.Color.cardStrokeQuiet : DS.Color.cardStroke, lineWidth: DS.Metric.cardBorder)
                }
            }
            .alignmentProbe(.cardEdge, measure: .frame)
            .padding(.vertical, DS.Space.cardGap / 2)
            .padding(.horizontal, DS.Space.cardEdge)
            .accessibilityHidden(true)
    }
}
