import SwiftUI

/// Design/CountPill: a section header's count, semibold monospaced digits on a soft capsule.
/// Not an accessibility element: the header's label says the count.
public struct CountPill: View {
    let text: String

    public init(count: Int) {
        self.text = "\(count)"
    }

    /// The same pill round a short tag ("+2 steps" on a queue card).
    public init(text: String) {
        self.text = text
    }

    public var body: some View {
        Text(verbatim: text)
            .font(DS.Font.countPill)
            .monospacedDigit()
            .foregroundStyle(DS.Color.primary)
            .padding(.horizontal, DS.Space.countPillH)
            .padding(.vertical, DS.Space.countPillV)
            .background(Capsule(style: .continuous).fill(DS.Color.countPillFill))
            .accessibilityHidden(true)
    }
}
