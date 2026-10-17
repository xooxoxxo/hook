import RelayCore
import SwiftUI

/// Design/RepliesList (design §3.2, §4.5): the replies already sent, each with its local time.
public struct RepliesList: View {
    let replies: [ReplyLine]

    public init(_ replies: [ReplyLine]) { self.replies = replies }

    public var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.stepPart) {
            ForEach(replies) { r in
                HStack(alignment: .firstTextBaseline) {
                    Text(prose(r.text))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Text(r.time).monospacedDigit().foregroundStyle(DS.Color.secondary)
                }
                .font(DS.Font.prose)
            }
        }
    }
}
