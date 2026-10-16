import RelayCore
import SwiftUI

/// One `Text` concatenation, so it shares a baseline with its neighbours. Inside a
/// selected row (`prominent`) the segments take the row's own foreground.
public func urgencyText(_ urgency: Urgency, prominent: Bool = false) -> Text {
    func segment(_ symbol: String, _ color: Color) -> Text {
        let word = Text(" " + urgency.word)
        if prominent { return Text(Image(systemName: symbol)) + word }
        return Text(Image(systemName: symbol)).foregroundStyle(color) + word.foregroundStyle(color)
    }
    switch urgency {
    case .now: return segment(DS.Symbol.now, DS.Color.now)
    case .today: return segment(DS.Symbol.today, DS.Color.today)
    case .whenever: return segment(DS.Symbol.whenever, DS.Color.whenever)
    case .unknown(let raw):
        return prominent ? Text(line(raw)) : Text(line(raw)).foregroundStyle(DS.Color.secondary)
    }
}

/// The urgency word as VoiceOver and plain text say it.
func urgencyWord(_ urgency: Urgency) -> String { line(urgency.word) }

/// Design/UrgencyLabel (design §3.2): symbol and word in the urgency's colour; an unknown
/// urgency shows its revealed raw string in `secondary`, with no symbol.
public struct UrgencyLabel: View {
    let urgency: Urgency
    public init(_ urgency: Urgency) { self.urgency = urgency }
    public var body: some View { urgencyText(urgency) }
}
