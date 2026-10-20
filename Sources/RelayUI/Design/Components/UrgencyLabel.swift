import RelayCore
import SwiftUI

/// One `Text` concatenation, so it shares a baseline with its neighbours. `word: false` leaves
/// only the symbol; an unknown urgency has no symbol and always shows its raw string.
public func urgencyText(_ urgency: Urgency, word: Bool = true) -> Text {
    func segment(_ symbol: String, _ color: Color) -> Text {
        let mark = Text(Image(systemName: symbol)).foregroundStyle(color)
        return word ? mark + Text(" " + urgency.word).foregroundStyle(color) : mark
    }
    switch urgency {
    case .now: return segment(DS.Symbol.now, DS.Color.now)
    case .today: return segment(DS.Symbol.today, DS.Color.today)
    case .whenever: return segment(DS.Symbol.whenever, DS.Color.whenever)
    case .unknown(let raw):
        return Text(line(raw)).foregroundStyle(DS.Color.secondary)
    }
}

/// The urgency word as VoiceOver and plain text say it.
func urgencyWord(_ urgency: Urgency) -> String { line(urgency.word) }

/// What a queue card's top row shows of its urgency. Now and Today show the symbol and the
/// word; under an Urgency section header, which already says the word, only the symbol.
/// Whenever shows nothing. An unknown urgency keeps its raw string, since no symbol or
/// header says it. VoiceOver reads the urgency on every card.
public enum CardUrgency: Equatable, Sendable {
    case hidden, symbol, symbolAndWord, raw

    public static func mark(_ urgency: Urgency, headerNamesIt: Bool) -> CardUrgency {
        switch urgency {
        case .now, .today: headerNamesIt ? .symbol : .symbolAndWord
        case .whenever: .hidden
        case .unknown: .raw
        }
    }
}

/// Design/UrgencyLabel: symbol and word in the urgency's colour; an unknown
/// urgency shows its revealed raw string in `secondary`, with no symbol.
public struct UrgencyLabel: View {
    let urgency: Urgency
    public init(_ urgency: Urgency) { self.urgency = urgency }
    public var body: some View { urgencyText(urgency) }
}
