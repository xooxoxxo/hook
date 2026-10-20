import RelayCore
import SwiftUI

/// Design/MonogramBadge: the project's two letters on its stable palette colour.
/// Decorative: the project name beside it is what VoiceOver reads.
public struct MonogramBadge: View {
    let project: String
    let quiet: Bool

    public init(project: String, quiet: Bool = false) {
        self.project = project
        self.quiet = quiet
    }

    public var body: some View {
        Text(line(Monogram.letters(project)))
            .font(DS.Font.monogram)
            .foregroundStyle(DS.Color.monogramText)
            .frame(width: DS.Metric.monogram, height: DS.Metric.monogram)
            .background(RoundedRectangle(cornerRadius: DS.Metric.monogramRadius, style: .continuous)
                .fill(DS.Color.monogram(project)))
            .opacity(quiet ? DS.Color.monogramQuietOpacity : 1)
            .accessibilityHidden(true)
    }
}
