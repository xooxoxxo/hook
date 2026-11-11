import SwiftUI

/// Design/CountPill: a section header's count, semibold monospaced digits on a soft capsule.
/// Not an accessibility element: the header's label says the count.
public struct CountPill: View {
    let count: Int

    public init(count: Int) {
        self.count = count
    }

    public var body: some View {
        Text("\(count)")
            .font(DS.Font.countPill)
            .monospacedDigit()
            .foregroundStyle(DS.Color.primary)
            .padding(.horizontal, DS.Space.countPillH)
            .padding(.vertical, DS.Space.countPillV)
            .background(Capsule(style: .continuous).fill(DS.Color.countPillFill))
            .accessibilityHidden(true)
    }
}
