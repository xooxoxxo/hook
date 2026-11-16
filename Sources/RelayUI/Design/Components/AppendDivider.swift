import SwiftUI

/// Design/AppendDivider: the line above the steps the session added to an open ask, with when
/// and why ("Added after your answer · 14:02", then the session's note). Both wrap on a narrow
/// panel, so the time is never cut. One VoiceOver element.
public struct AppendDivider: View {
    let title: String
    let note: String

    public init(title: String, note: String) {
        self.title = title
        self.note = note
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.rowLine) {
            Divider()
            Label {
                Text(verbatim: title)
            } icon: {
                Image(systemName: DS.Symbol.stepAdded)
            }
            .font(DS.Font.meta)
            .foregroundStyle(DS.Color.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, DS.Space.stepPart)
            if !note.isEmpty {
                Text(verbatim: note)
                    .font(DS.Font.meta)
                    .foregroundStyle(DS.Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
