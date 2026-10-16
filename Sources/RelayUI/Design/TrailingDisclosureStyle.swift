import SwiftUI

/// Design/TrailingDisclosureStyle (design §3.2): the label is a plain button that toggles the group,
/// with a small trailing chevron, so the label text starts on the same x as its siblings' text.
public struct TrailingDisclosureStyle: DisclosureGroupStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        TrailingDisclosureBody(configuration: configuration)
    }

    /// The disclosure button's VoiceOver value.
    public static func value(expanded: Bool) -> String { expanded ? "Expanded" : "Collapsed" }
}

private struct TrailingDisclosureBody: View {
    let configuration: DisclosureGroupStyleConfiguration
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(DS.motion(DS.Motion.reveal, reduce: reduceMotion)) {
                    configuration.isExpanded.toggle()
                }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: DS.Space.inline) {
                    configuration.label
                    Spacer(minLength: DS.Space.inline)
                    Image(systemName: configuration.isExpanded ? DS.Symbol.disclosureOpen : DS.Symbol.disclosureClosed)
                        .imageScale(.small)
                        .foregroundStyle(DS.Color.secondary)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityValue(TrailingDisclosureStyle.value(expanded: configuration.isExpanded))
            if configuration.isExpanded {
                configuration.content
                    .transition(.opacity)
            }
        }
    }
}

extension DisclosureGroupStyle where Self == TrailingDisclosureStyle {
    public static var trailing: TrailingDisclosureStyle { TrailingDisclosureStyle() }
}
