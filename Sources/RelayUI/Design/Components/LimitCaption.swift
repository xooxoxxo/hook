import RelayCore
import SwiftUI

/// Design/LimitCaption: what a field says about its cap (shared by Messages, the inline report
/// and a choice's words). The counter shows only past 80 % of the limit and turns red over it;
/// over the limit the trim line says how much to cut. The text is never cut for the owner.
public struct LimitCounter: View {
    let count: Int
    let limit: Int

    public init(count: Int, limit: Int) {
        self.count = count
        self.limit = limit
    }

    public var body: some View {
        if TalkLimits.showsCounter(count, limit: limit) {
            Text(TalkLimits.counter(count, limit: limit))
                .font(DS.Font.meta)
                .monospacedDigit()
                .foregroundStyle(count > limit ? DS.Color.errorText : DS.Color.secondary)
                .accessibilityLabel("\(count) of \(limit) characters")
        }
    }
}

/// "Trim 1 204 characters to send.", in the error colour, over the limit; nothing otherwise.
public struct LimitCaption: View {
    let count: Int
    let limit: Int

    public init(count: Int, limit: Int) {
        self.count = count
        self.limit = limit
    }

    /// The line, or nil at or under the limit.
    public static func text(count: Int, limit: Int) -> String? { TalkLimits.over(count, limit: limit) }

    public var body: some View {
        if let line = Self.text(count: count, limit: limit) {
            Text(line)
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.errorText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
